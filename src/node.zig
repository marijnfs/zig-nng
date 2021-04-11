const std = @import("std");
const fmt = std.fmt;
const AutoHashMap = std.AutoHashMap;
const Thread = std.Thread;
const warn = std.debug.warn;

const c = @import("c.zig").c;
const AtomicQueue = @import("queue.zig").AtomicQueue;
const nng_ret = @import("c.zig").nng_ret;
const logger = @import("logger.zig");
const model = @import("model.zig");

const display = @import("display.zig");

const defines = @import("defines.zig");
const Guid = defines.Guid;
const ID = defines.ID;
const Block = defines.Block;
const Address = defines.Address;
const allocator = defines.allocator;

const serialise_msg = @import("serialise.zig").serialise_msg;
const deserialise_msg = @import("serialise.zig").deserialise_msg;

const workers = @import("workers.zig");
const InWork = workers.InWork;
const OutWork = workers.OutWork;

// Guid that will be used to signify self-id
pub var my_id: ID = std.mem.zeroes(ID);
pub var my_address: ?Address = undefined;
pub var my_port: u16 = 0;

var nearest_ID: ID = std.mem.zeroes(ID);
var closest_distance: ID = std.mem.zeroes(ID);

var event_queue = AtomicQueue(Job).init(allocator);

// Threads
var event_thread: *Thread = undefined;
var timer_thread: *Thread = undefined;
var read_lines_thread: *Thread = undefined;

// Database which holds known items
var database = std.AutoHashMap(ID, Block).init(allocator);

// Map holding ID -> Map
var peers = std.AutoHashMap(ID, Address).init(allocator);

// Known addresses to bootstrap
pub var known_addresses = std.ArrayList(Address).init(allocator);

pub var line_buffer = std.ArrayList(u8).init(allocator);

// Addresses to self
// keep multiple, because they can change depending on locality
pub var self_addresses = std.StringHashMap(bool).init(allocator);

// Guid filter to not rebroadcast messages
// TODO: make rolling hash map
pub var guid_seen = std.AutoHashMap(Guid, bool).init(allocator);

// Guid filter to check messages to self (as opposed to passed on messages, which should be routed further)
//
pub var self_guids = std.AutoHashMap(Guid, bool).init(allocator); //Guid filter for self-addressed guids. Used to distinguish between messages to procress / pass on

// Our routing table
// Key's will be finger table base
// Values will be actual peers
// Will be periodically updated and queried to make actual connection
const PeerInfo = struct {
    id: ID, //ID of the peer
    address: ?Address = undefined, //connection end point to connect to this peer
};
pub var finger_table = std.AutoHashMap(ID, PeerInfo).init(allocator);

// Our connections
pub var connections = std.ArrayList(*Connection).init(allocator);

var incoming_workers: [defines.N_INCOMING_WORKERS]*InWork = undefined;
var outgoing_workers = std.ArrayList(*OutWork).init(allocator);

var main_socket: c.nng_socket = undefined;

const Connection = @import("connection.zig");

const requests = @import("requests.zig");
const Request = requests.Request;
const handle_request = requests.handle_request;

const responses = @import("responses.zig");
const Response = responses.Response;
const handle_response = responses.handle_response;

const GuidKeyValue = struct {
    guid: u64 = 0, //source of request
    key: ID,
    value: ?[]u8 = undefined,
};

fn OutEnvelope(comptime T: type) type {
    return struct {
        enveloped: T,
        conn_guid: Guid = 0, //Guid for interal addressing of output connection
        guid: Guid = 0, //request processing id
        msg: *c.nng_msg = undefined,
    };
}

fn Envelope(comptime T: type) type {
    return struct {
        enveloped: T,
        guid: Guid = 0, //request processing id
        msg: *c.nng_msg = undefined,
    };
}

const RequestEnvelope = OutEnvelope(Request);

const ResponseEnvelope = Envelope(Response);

const HandleStdinLine = struct {
    buffer: []u8,
};

pub const Message = struct {
    id: ID = undefined, //recipient
    content: []u8 = undefined,
};

pub fn connection_by_guid(guid: Guid) !*Connection {
    for (connections.items) |conn| {
        logger.log_fmt("Looking {} {}\n", .{ conn.guid, guid });
        if (conn.guid == guid) {
            return conn;
        }
    }
    return error.NotFound;
}

pub fn connection_by_nearest_id(id: ID) !*Connection {
    if (connections.items.len == 0)
        return error.NotFound;

    var first = true;
    var nearest_conn: *Connection = undefined;
    var nearest_dist = std.mem.zeroes(ID);

    for (connections.items) |conn| {
        if (conn.state != .Disconnected and conn.id_known()) {
            const dist = xor(conn.id, id);
            if (first or less(dist, nearest_dist)) {
                nearest_dist = dist;
                nearest_conn = conn;
                first = false;
            }
        }
    }

    if (first)
        return error.NotFound;
    return nearest_conn;
}

pub fn is_self_address(address: []u8) bool {
    var it = self_addresses.iterator();
    while (it.next()) |kv| {
        const self_address = kv.key;
        if (std.mem.eql(u8, address, self_address)) {
            return true;
        }
    }
    return false;
}

pub fn address_is_connected(address: Address) bool {
    for (connections.items) |conn| {
        if (std.mem.eql(u8, address, conn.address)) {
            return true;
        }
    }
    return false;
}

// Rudimentary console
fn read_lines(context: void) !void {
    logger.log_fmt("Console started\n", .{});

    var buf: [4096]u8 = undefined;

    while (true) {
        const line = (std.io.getStdIn().reader().readUntilDelimiterAlloc(allocator, '\n', std.math.maxInt(usize)) catch |e| switch (e) {
            error.EndOfStream => {
                logger.log_fmt("=Console Ending=\n", .{});
                return;
            },
            else => return e,
        });
        try enqueue(Job{ .handle_stdin_line = .{ .buffer = line } });
    }
}

pub fn enqueue(job: Job) !void {
    // logger.log_fmt("queuing job: {}\n", .{job});
    try event_queue.push(job);
}

pub const Job = union(enum) {
    connect: Address,
    store: GuidKeyValue,
    get: GuidKeyValue,
    bootstrap: usize,

    handle_request: RequestEnvelope,
    handle_response: ResponseEnvelope,

    send_request: RequestEnvelope,
    send_response: ResponseEnvelope,

    // handle_stdin_line: HandleStdinLine,
    process_key: []const u8,

    manage_connections: usize, //void has issues, so we use usize
    refresh_finger_table: usize, //void has issues, so we use usize
    redraw: usize, //void has issues, so we use usize
    shutdown: usize, //void has issues, so we use usize
    sync_finger_table: usize, //void has issues

    add_message_to_model: Message,
    introduce_message: Message,
    broadcast_msg: Envelope(Message),

    fn work(self: *Job) !void {

        // logger.log_fmt("run job: {}\n", .{self.*});

        switch (self.*) {
            .introduce_message => |message| {
                const guid = defines.get_guid();

                try enqueue(Job{ .add_message_to_model = message });
                try enqueue(Job{ .broadcast_msg = .{ .guid = guid, .enveloped = message } });
            },
            .add_message_to_model => |message| {
                try model.add_message(message.content);
                try enqueue(Job{ .redraw = 0 });
            },
            .broadcast_msg => {
                const message = self.broadcast_msg.enveloped;
                const guid = self.broadcast_msg.guid;

                // Check if broadcasted already, Dont broadcast again
                if (guid_seen.get(guid)) |seen| {
                    return;
                }
                try guid_seen.put(guid, true);

                for (connections.items) |conn| {
                    if (conn.state != .Disconnected and conn.id_known()) {
                        try enqueue(Job{ .send_request = .{ .conn_guid = conn.guid, .guid = guid, .enveloped = .{ .broadcast = .{ .content = message.content } } } });
                    }
                }
            },
            .send_request => {
                const conn_guid = self.send_request.conn_guid;
                const guid = self.send_request.guid;
                var conn = try connection_by_guid(conn_guid);

                const request = self.send_request.enveloped;

                var request_msg: ?*c.nng_msg = undefined;
                try nng_ret(c.nng_msg_alloc(&request_msg, 0));

                // First set the guid
                try nng_ret(c.nng_msg_append_u64(request_msg, guid));

                try serialise_msg(request, request_msg.?);

                logger.log_fmt("routing request to worker: {any}\n", .{outgoing_workers.items});
                for (outgoing_workers.items) |out_worker| {
                    if (out_worker.accepting() and out_worker.connection == conn) {
                        logger.log_fmt("selected out_worker {}\n", .{out_worker});

                        out_worker.send(request_msg.?);

                        return;
                    }
                }

                // If we get here nothing was sent, reschedule
                logger.log_fmt("drop message: {}\n", .{self.*});
                // try enqueue(self.*);
            },
            .send_response => {
                const guid = self.send_response.guid;
                const response = self.send_response.enveloped;
                var response_msg: ?*c.nng_msg = undefined;
                try nng_ret(c.nng_msg_alloc(&response_msg, 0));

                // First set the guid
                try nng_ret(c.nng_msg_append_u64(response_msg, guid));

                try serialise_msg(response, response_msg.?);

                logger.log_fmt("Sending response, guid {}, msg: {}\n", .{ guid, response_msg });
                for (incoming_workers) |w| {
                    if (w.guid == guid and w.state == .Wait) {
                        logger.log_fmt("Found matching worker, sending response: {}\n", .{w});
                        w.send(response_msg.?);
                        break;
                    }
                } else {
                    logger.log_fmt("Couldn't respond, guid: {any}, workers: {any}\n", .{ guid, incoming_workers });
                }
            },
            .store => {
                logger.log_fmt("store\n", .{});
                const key = self.store.key;
                const value = self.store.value;
                if (in_my_range(key)) //store here
                {
                    try database.put(key, value.?);
                } else {}
            },
            .get => {
                logger.log_fmt("get {}\n", .{self.get});
            },
            .handle_request => {
                logger.log_fmt("handle request\n", .{});
                const guid = self.handle_request.guid;
                const request = self.handle_request.enveloped;
                const msg = self.handle_request.msg;

                try handle_request(guid, request, msg);
            },
            .bootstrap => {
                logger.log_fmt("bootstrap: {any}\n", .{known_addresses.items});
                var n = self.bootstrap;
                if (known_addresses.items.len < n)
                    n = known_addresses.items.len;

                var i: usize = 0;
                while (i < n) : (i += 1) {
                    var address = known_addresses.items[i];
                    try enqueue(Job{ .connect = address });
                }
            },
            .connect => |address| {
                logger.log_fmt("connect\n", .{});

                // Setup connection
                if (address_is_connected(address)) {
                    logger.log_fmt("already connecting, skipping {s}\n", .{address});
                    return;
                }

                var conn = try Connection.alloc();
                conn.init(address);
                try conn.req_open();
                try conn.dial();

                try connections.append(conn);

                // Create a worker
                logger.log_fmt("connect on socket: {}\n", .{conn.socket});
                var out_worker = try OutWork.alloc(conn);
                try outgoing_workers.append(out_worker);

                const guid = defines.get_guid();
                try self_guids.put(guid, true); //register that this guid is to be processed by us
                const conn_guid = conn.guid;
                try enqueue(Job{ .send_request = .{ .conn_guid = conn_guid, .guid = guid, .enveloped = .{ .ping_id = .{ .conn_guid = conn_guid, .port = my_port } } } });
            },

            .handle_response => {
                const guid = self.handle_response.guid;
                const response = self.handle_response.enveloped;
                try handle_response(guid, response);
            },
            .manage_connections => {
                // disconnect to things not in finters

                // Remove bad connections
                var i: usize = 0;
                while (i < connections.items.len) {
                    if (connections.items[i].state == .Disconnected) {
                        connections.items[i].free();
                        _ = connections.orderedRemove(i);
                    } else {
                        i += 1;
                    }
                }
            },
            .refresh_finger_table => {
                // The routing table is a hash map, with desired finger IDs as keys, and the closest matches as values
                // We periodially
                var it = finger_table.iterator();
                while (it.next()) |kv| {
                    const find_id = kv.key;
                    // we want to send the request to the nearest peer to the ID
                    // If there are no matching connections, we can't send the request
                    const connection = connection_by_nearest_id(find_id) catch {
                        continue;
                    };
                    const guid = defines.get_guid();
                    try self_guids.put(guid, true);
                    try enqueue(Job{ .send_request = .{ .conn_guid = connection.guid, .guid = guid, .enveloped = .{ .nearest_peer = find_id } } });
                }
            },
            .sync_finger_table => {
                // connect to items in fingers
                var temp_hash_map = std.StringHashMap(bool).init(allocator);
                defer temp_hash_map.deinit();

                var it = finger_table.iterator();
                while (it.next()) |kv| {
                    if (kv.value.address) |address| {
                        if (address_is_connected(address) or is_self_address(address)) {
                            // address is already connected
                            logger.log_fmt("not adding, already connected or self address: {s}\n", .{address});
                            continue;
                        }

                        if (temp_hash_map.get(address)) |_| {
                            // already requested
                        } else {
                            logger.log_fmt("Requesting peer connection to: {s}\n", .{address});

                            try enqueue(Job{ .connect = address });
                            try temp_hash_map.put(address, true);
                        }
                    }
                }
            },
            .shutdown => {
                try display.deinit();
                unreachable;
            },
            .process_key => |process_key| {
                const key = process_key[0];

                if (key == 13) { //Return Key
                    try enqueue(Job{ .introduce_message = .{ .content = line_buffer.items } });
                    try line_buffer.resize(0);
                } else {
                    try line_buffer.append(key);
                }
                try enqueue(Job{ .redraw = 0 });
            },
            .redraw => {
                try display.draw();
            },
        }
    }
};

fn event_queue_threadfunc(context: void) void {
    while (true) {
        if (event_queue.pop()) |*job| {
            job.work() catch |e| {
                logger.log_fmt("Work Error: {}\n", .{e});
            };
        } else {
            c.nng_msleep(10);
        }
    }
}

fn get_finger_id(id: ID, bit: usize) ID {
    // 256 bits = 64 bytes
    // We find the index in the byte (bit_id)
    // We find the byte (byte_id)
    const byte_id: usize = bit / 8;
    const single_byte: u3 = @intCast(u3, bit % 8);

    // convert to bit index
    const bit_id: u3 = @intCast(u3, 7 - single_byte);

    var new_id = id;
    new_id[byte_id] = id[byte_id] ^ (@as(u8, 1) << bit_id); //xor byte with bit in correct place
    return new_id;
}

pub fn xor(id1: ID, id2: ID) ID {
    var result: ID = id1;
    for (result) |r, i| {
        result[i] = r ^ id2[i];
    }
    return result;
}

pub fn less(id1: ID, id2: ID) bool {
    return std.mem.order(u8, id1[0..], id2[0..]) == .lt;
}

pub fn in_my_range(id: ID) bool {
    var dist = xor(my_id, id);
    return less(id, closest_distance);
}

pub fn rand_id() ID {
    var id: ID = undefined;
    std.crypto.random.bytes(&id);
    return id;
}

pub fn is_zero(id: ID) bool {
    for (id) |d| {
        if (d != 0)
            return false;
    }
    return true;
}

fn init() !void {
    try logger.init_log();
    defines.init();

    logger.log_fmt("Init\n", .{});
    my_id = rand_id();

    logger.log_fmt("My ID: {x}\n", .{std.fmt.fmtSliceHexLower(my_id[0..])});

    logger.log_fmt("Filling routing table\n", .{});
    var i: usize = 0;
    while (i < defines.ROUTING_TABLE_SIZE) : (i += 1) {
        var other_id = get_finger_id(my_id, i);
        try finger_table.put(other_id, PeerInfo{ .id = std.mem.zeroes(ID) });
        logger.log_fmt("Finger table {}: {x}\n", .{ i, std.fmt.fmtSliceHexLower(other_id[0..]) });
    }

    event_thread = try Thread.spawn(event_queue_threadfunc, {});
    timer_thread = try Thread.spawn(timer_threadfunc, {});
    // read_lines_thread = try Thread.spawn(read_lines, {});
    try display.start_display_thread();
}

fn ceil_log2(n: usize) usize {
    if (n == 0)
        return 0;
    return @floatToInt(usize, std.math.log2(@intToFloat(f64, n)));
}

//thread to periodically queue work
fn timer_threadfunc(context: void) !void {
    logger.log_fmt("Timer thread\n", .{});
    while (true) {
        c.nng_msleep(4000);
        try enqueue(Job{ .bootstrap = 1 });
        try enqueue(Job{ .manage_connections = 0 });
        c.nng_msleep(4000);
        try enqueue(Job{ .refresh_finger_table = 0 });
        c.nng_msleep(4000);
        try enqueue(Job{ .sync_finger_table = 0 });
    }
}

pub fn main() !void {
    try init();

    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        logger.log_fmt("usage: {s} <url> <port> <connections>, eg url=tcp://localhost 1234 \n", .{args[0]});
        std.os.exit(1);
    }

    const address = try std.cstr.addNullByte(allocator, args[1]);
    defer allocator.free(address);

    my_port = try std.fmt.parseInt(u16, args[2], 10);
    logger.log_fmt("Setting up server, with ip: {s}, port: {}\n", .{ address, my_port });

    for (args[3..]) |out_addr| {
        const out_addr_null = try std.cstr.addNullByte(allocator, out_addr);
        logger.log_fmt("Adding {s} to known addresses\n", .{out_addr_null});
        try known_addresses.append(out_addr_null);
    }

    try nng_ret(c.nng_rep0_open(&main_socket));

    for (incoming_workers) |*w| {
        w.* = try InWork.alloc(main_socket);
    }

    try nng_ret(c.nng_listen(main_socket, address, 0, 0));

    logger.log_fmt("listening on {s}", .{address});
    for (incoming_workers) |w| {
        workers.inWorkCallback(w.toOpaque());
    }

    try enqueue(Job{ .bootstrap = 1 });
    try enqueue(Job{ .redraw = 0 });

    event_thread.wait();
}

test "serialiseTest" {
    var search_id: ID = undefined;
    var nearest_id: ID = undefined;
    var nearest_peer = Response{ .nearest_peer = .{ .search_id = search_id, .nearest_id = nearest_id, .address = null } };

    var msg: ?*c.nng_msg = undefined;
    try nng_ret(c.nng_msg_alloc(&msg, 0));
    try serialise_msg(nearest_peer, msg.?);
}

test "connectTest" {
    var conn_1 = try Connection.alloc();
    var conn_2 = try Connection.alloc();

    var bind_point = "tcp://172.0.0.1:1234";
    conn_1.init(bind_point);
    conn_2.init(bind_point);

    try conn_1.req_open();
    try conn_1.dial();

    try conn_2.rep_open();
    try conn_2.listen();
}
