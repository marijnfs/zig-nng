const std = @import("std");
const fmt = std.fmt;
const ArrayList = std.ArrayList;
const AutoHashMap = std.AutoHashMap;
const Thread = std.Thread;
const warn = std.debug.warn;

const c = @import("c.zig").c;
const AtomicQueue = @import("queue.zig").AtomicQueue;
const nng_ret = @import("c.zig").nng_ret;

const defines = @import("defines.zig");
const Guid = defines.Guid;
const ID = defines.ID;
const Block = defines.Block;
const allocator = defines.allocator;

const serialise_msg = @import("serialise.zig").serialise_msg;
const deserialise_msg = @import("serialise.zig").deserialise_msg;

const workers = @import("workers.zig");
const InWork = workers.InWork;
const OutWork = workers.OutWork;

// Guid that will be used to signify self-id
pub var self_guid: Guid = undefined;

pub var my_id: ID = std.mem.zeroes(ID);
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
var peers = std.AutoHashMap(ID, [:0]u8).init(allocator);

// Known addresses to bootstrap
pub var known_addresses = std.ArrayList([:0]u8).init(allocator);

// Addresses to self
pub var self_addresses = std.StringHashMap(bool).init(allocator);

pub var guid_seen = std.AutoHashMap(Guid, bool).init(allocator);

// Our routing table
// Key's will be finger table base
// Values will be actual peers
// Will be periodically updated and queried to make actual connection
const PeerInfo = struct {
    id: ID,
    address: [:0]u8,
};
var routing_table = std.AutoHashMap(ID, PeerInfo).init(allocator);

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

const Bootstrap = struct {
    n: usize,
};

const Connect = struct {
    address: [:0]const u8,
};

fn Envelope(comptime T: type) type {
    return struct {
        enveloped: T,
        conn_guid: Guid = 0, //Guid for interal addressing of output connection
        guid: Guid = 0, //request processing id
        msg: *c.nng_msg = undefined,
    };
}

const RequestEnvelope = Envelope(Request);
// const RequestEnvelope = struct {
//     conn_guid: Guid, //Guid for interal addressing of output connection
//     guid: Guid = 0, //request processing id
//     request: Request, msg: *c.nng_msg = undefined
// };

const ResponseEnvelope = Envelope(Response);
// struct {
//     guid: Guid = 0, //internal processing id
//     id: ID = undefined, //recipient
//     response: Response,
// };

const HandleStdinLine = struct {
    buffer: []u8,
};

pub const Message = struct {
    id: ID = undefined, //recipient
    content: []u8 = undefined,
};

pub fn connection_by_guid(guid: Guid) !*Connection {
    for (connections.items) |conn| {
        warn("Looking {} {}\n", .{ conn.guid, guid });
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

// Rudimentary console
fn read_lines(context: void) !void {
    warn("Console started\n", .{});

    var buf: [4096]u8 = undefined;

    while (true) {
        const line = (std.io.getStdIn().reader().readUntilDelimiterAlloc(allocator, '\n', std.math.maxInt(usize)) catch |e| switch (e) {
            error.EndOfStream => {
                warn("=Console Ending=\n", .{});
                return;
            },
            else => return e,
        });
        try enqueue(Job{ .handle_stdin_line = .{ .buffer = line } });
    }
}

pub fn enqueue(job: Job) !void {
    try event_queue.push(job);
}

pub const Job = union(enum) {
    connect: Connect,
    store: GuidKeyValue,
    get: GuidKeyValue,
    bootstrap: Bootstrap,

    handle_request: RequestEnvelope,
    handle_response: ResponseEnvelope,

    send_request: RequestEnvelope,
    send_response: ResponseEnvelope,

    handle_stdin_line: HandleStdinLine,
    manage_connections: void,
    refresh_routing_table: void,

    print_msg: Message,
    broadcast_msg: Envelope(Message),

    fn work(self: *Job) !void {
        warn("work: {}\n", .{self.*});
        switch (self.*) {
            .print_msg => {
                warn("Msg: {s}\n", .{self.print_msg.content});
            },
            .broadcast_msg => {
                const message = self.broadcast_msg.enveloped;
                const guid = self.broadcast_msg.guid;
                for (connections.items) |conn| {
                    if (conn.state != .Disconnected and conn.id_known()) {
                        try enqueue(Job{ .send_request = .{ .conn_guid = conn.guid, .guid = guid, .enveloped = .{ .broadcast = .{ .content = message.content } } } });
                    }
                }
            },
            .send_request => {
                const conn_guid = self.send_request.conn_guid;
                const guid = self.send_request.guid;
                var conn = connection_by_guid(conn_guid);

                const request = self.send_request.enveloped;

                var request_msg: ?*c.nng_msg = undefined;
                try nng_ret(c.nng_msg_alloc(&request_msg, 0));

                // First set the guid
                try nng_ret(c.nng_msg_append_u64(request_msg, guid));

                try serialise_msg(request, request_msg.?);

                warn("n outgoing: {}\n", .{outgoing_workers.items});
                for (outgoing_workers.items) |out_worker| {
                    if (out_worker.accepting() and out_worker.guid == conn_guid) {
                        warn("selected out_worker {}\n", .{out_worker});

                        out_worker.send(request_msg.?);

                        return;
                    }
                }

                // If we get here nothing was sent, reschedule
                warn("reschedule\n", .{});
                try enqueue(self.*);
            },
            .send_response => {
                const guid = self.send_response.guid;
                const response = self.send_response.enveloped;
                var response_msg: ?*c.nng_msg = undefined;
                try nng_ret(c.nng_msg_alloc(&response_msg, 0));

                // First set the guid
                try nng_ret(c.nng_msg_append_u64(response_msg, guid));

                try serialise_msg(response, response_msg.?);

                warn("Sending response, guid {}, msg: {}\n", .{ guid, response_msg });
                for (incoming_workers) |w| {
                    if (w.guid == guid and w.state == .Wait) {
                        warn("Found matching worker, sending response: {}\n", .{w});
                        w.send(response_msg.?);
                        break;
                    }
                } else {
                    warn("Couldn't response, guid: {}, workers: {}\n", .{ guid, incoming_workers });
                }
            },
            .store => {
                warn("store\n", .{});
                const key = self.store.key;
                const value = self.store.value;
                if (in_my_range(key)) //store here
                {
                    try database.put(key, value.?);
                } else {}
            },
            .get => {
                warn("get {}\n", .{self.get});
            },
            .handle_request => {
                warn("handle request\n", .{});
                const guid = self.handle_request.guid;
                const request = self.handle_request.enveloped;
                const msg = self.handle_request.msg;

                try handle_request(guid, request, msg);
            },
            .bootstrap => {
                warn("bootstrap: {}\n", .{known_addresses.items});
                var n = self.bootstrap.n;
                if (known_addresses.items.len < n)
                    n = known_addresses.items.len;

                var i: usize = 0;
                while (i < n) : (i += 1) {
                    var address = known_addresses.items[i];
                    try enqueue(Job{ .connect = .{ .address = address } });
                }
            },
            .connect => {
                warn("connect\n", .{});

                // Setup connection
                var address = self.connect.address;
                var conn = try Connection.alloc();
                conn.init(address);
                try conn.req_open();
                try conn.dial();

                try connections.append(conn);

                // Create a worker
                warn("connect on socket: {}\n", .{conn.socket});
                var out_worker = try OutWork.alloc(conn.socket);
                out_worker.guid = conn.guid;
                try outgoing_workers.append(out_worker);

                const conn_guid = conn.guid;
                try enqueue(Job{ .send_request = .{ .conn_guid = conn.guid, .guid = defines.get_guid(), .enveloped = .{ .ping_id = .{ .conn_guid = conn_guid } } } });
            },

            .handle_response => {
                const guid = self.handle_response.guid;
                const response = self.handle_response.enveloped;
                warn("got: {}\n", .{self.handle_response});
                try handle_response(guid, response);
            },
            .handle_stdin_line => {
                const buf = self.handle_stdin_line.buffer;
                const space = std.mem.indexOf(u8, buf, " ");
                if (space) |idx| {
                    const key = buf[0..idx];
                    const hash = calculate_hash(key);
                    const value = buf[idx + 1 ..];
                    if (std.mem.eql(u8, key, "store")) {
                        try enqueue(Job{ .store = .{ .key = hash, .value = value } });
                    } else {
                        try enqueue(Job{ .print_msg = .{ .content = value } });
                        try enqueue(Job{
                            .broadcast_msg = .{
                                .guid = defines.get_guid(),
                                .enveloped = .{ .content = value },
                            },
                        });
                    }
                } else {
                    const key = buf;
                    const hash = calculate_hash(key);

                    try enqueue(Job{ .get = .{ .key = hash, .guid = 0 } });
                }
            },
            .manage_connections => {
                //check if there are any connections
                warn("Found {} connections\n", .{connections.items});
                if (connections.items.len == 0) {
                    warn("no connections found, looking for more\n", .{});
                    if (known_addresses.items.len == 0) {
                        warn("No connections, no known addresses\n", .{});
                        return;
                    }
                    const r = defines.rng.random.uintLessThan(usize, known_addresses.items.len);
                    try enqueue(Job{
                        .connect = .{ .address = known_addresses.items[r] },
                    });
                }
            },
            .refresh_routing_table => {},
        }
    }
};

fn event_queue_threadfunc(context: void) void {
    while (true) {
        if (event_queue.pop()) |*job| {
            job.work() catch |e| {
                warn("e {}\n", .{e});
            };
        } else {
            // warn("sleeping\n", .{});
            c.nng_msleep(100);
        }
    }
}

fn get_finger_id(id: ID, bit: usize) ID {
    const byte_id: usize = bit / 8;
    const bit_id: u3 = @intCast(u3, 7 - bit % 8);
    var new_id = id;
    new_id[byte_id] = id[byte_id] ^ (@as(u8, 1) << bit_id);
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

pub fn calculate_hash(data: []const u8) ID {
    var result: ID = undefined;
    std.crypto.hash.Blake3.hash(data, result[0..], .{});
    return result;
}

pub fn rand_id() ID {
    var id: ID = undefined;
    std.crypto.random.bytes(&id);
    return id;
}

fn init() !void {
    defines.init();

    self_guid = defines.get_guid();

    warn("Init\n", .{});
    my_id = rand_id();

    warn("My ID: {x}\n", .{my_id});

    var other_id = get_finger_id(my_id, 0);
    warn("other id: {x}\n", .{other_id});

    event_thread = try Thread.spawn({}, event_queue_threadfunc);
    timer_thread = try Thread.spawn({}, timer_threadfunc);
    read_lines_thread = try Thread.spawn({}, read_lines);
}

fn ceil_log2(n: usize) usize {
    if (n == 0)
        return 0;
    return @floatToInt(usize, std.math.log2(@intToFloat(f64, n)));
}

//thread to periodically queue work
fn timer_threadfunc(context: void) !void {
    warn("Timer thread\n", .{});
    while (true) {
        c.nng_msleep(10000);
        try enqueue(Job{ .manage_connections = {} });
        c.nng_msleep(10000);
        warn("info, connections:{}\n", .{connections.items});
    }
}

pub fn main() !void {
    try init();

    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.warn("usage: {} <url>, eg url=tcp://localhost:8123\n", .{args[0]});
        std.os.exit(1);
    }

    const address = try std.cstr.addNullByte(allocator, args[1]);
    defer allocator.free(address);

    for (args[2..]) |out_addr| {
        const out_addr_null = try std.cstr.addNullByte(allocator, out_addr);
        warn("Adding {s} to known addresses\n", .{out_addr_null});
        try known_addresses.append(out_addr_null);
    }

    try nng_ret(c.nng_rep0_open(&main_socket));

    for (incoming_workers) |*w| {
        w.* = try InWork.alloc(main_socket);
    }

    try nng_ret(c.nng_listen(main_socket, address, 0, 0));

    warn("listening on {s}", .{address});
    for (incoming_workers) |w| {
        workers.inWorkCallback(w.toOpaque());
    }

    try enqueue(Job{ .bootstrap = .{ .n = 4 } });

    event_thread.wait();
}

test "serialise" {
    var sock_main: c.nng_msg = undefined;
    try nng_ret(c.nng_rep0_open(&main_socket));
}
