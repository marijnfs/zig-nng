const std = @import("std");
const ArrayList = std.ArrayList;
const AutoHashMap = std.AutoHashMap;
const Thread = std.Thread;
const AtomicQueue = @import("queue.zig").AtomicQueue;

const crypto = std.crypto;

const c = @import("c.zig").c;
const warn = std.debug.warn;

const allocator = std.heap.page_allocator;
const ID_SIZE = 32;
const ID = [32]u8;

const N_INCOMING_WORKERS = 4;
const N_OUTGOING_WORKERS = 4;

// We are currently going for 64kb blocks
const BIT_PER_BLOCK = 16;
const BLOCK_SIZE = 1 << BIT_PER_BLOCK;
const ROUTING_TABLE_SIZE = 16;

const Block = []u8;

const Guid = u64;

var my_id: ID = undefined;
var closest_distance: ID = undefined;
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
var known_addresses = std.ArrayList([:0]u8).init(allocator);

// Our routing table
var routing_table = std.ArrayList(*Connection).init(allocator);

var incoming_workers: [N_INCOMING_WORKERS]*InWork = undefined;
var outgoing_workers = std.ArrayList(*OutWork).init(allocator);

var main_socket: c.nng_socket = undefined;

var rng = std.rand.DefaultPrng.init(0);

const Connection = struct {
    guid: Guid,
    address: [:0]const u8,

    id: ID = undefined,
    n_workers: usize = 0,
    socket: c.nng_socket = undefined,

    fn id_known() bool {
        for (id) |d| {
            if (d != 0)
                return true;
        }
        return false;
    }

    fn alloc() !*Connection {
        return try allocator.create(Connection);
    }

    fn init(self: *Connection, address: [:0]const u8) void {
        self.* = Connection{
            .address = address,
            .guid = get_guid(),
        };

        std.mem.set(u8, self.id[0..], 0);
    }

    fn req_open(
        self: *Connection,
    ) !void {
        warn("req open {s}\n", .{self.address});
        var r: c_int = undefined;
        try nng_ret(c.nng_req0_open(&self.socket));
    }

    fn rep_open(self: *Connection) !void {
        warn("rep open {s}\n", .{self.address});
        var r: c_int = undefined;
        try nng_ret(c.nng_rep0_open(self.sock));
    }

    fn dial(self: *Connection) !void {
        warn("dialing {s}\n", .{self.address});
        try nng_ret(c.nng_dial(self.socket, self.address, 0, 0));
    }
};

const Store = struct {
    guid: u64, //source of request
    key: ID,
    value: []u8,
};

const Get = struct {
    guid: u64, //source of request
    key: ID,
};

const PingID = struct {
    guid: Guid, //target connection guid
};

const Bootstrap = struct {
    n: usize,
};

const Connect = struct {
    address: [:0]const u8,
};

const SendMessage = struct {
    id: ID, //recipient
    guid: Guid, //internal processing id
    msg: *c.nng_msg,
};

const Reply = struct {
    guid: Guid,
    msg: *c.nng_msg,
};

const HandleRequest = struct {
    operand: Operand,
    guid: Guid,
    msg: *c.nng_msg,
};

const HandleResponse = struct {
    guid: Guid, //id from response
    msg: *c.nng_msg, //message to process
};

const HandleStdinLine = struct {
    buffer: []u8,
};

fn connection_by_guid(guid: Guid) !*Connection {
    for (routing_table.items) |conn| {
        if (conn.guid == guid) {
            return conn;
        }
    }
    return error.NotFound;
}

fn connection_by_nearest_id(id: ID) !*Connection {
    for (routing_table.items) |conn| {
        if (conn.state != .Unconnected and less(conn.ID, id)) {
            return conn;
        }
    }

    return error.NotFound;
}

// Rudimentary console
fn read_lines(context: void) !void {
    warn("Console started\n", .{});

    var buf: [4096]u8 = undefined;
    // const stdout = std.io.getStdOut().inStream();
    // const readUntil = stdin.readUntilDelimiterOrEof;

    while (true) {
        const line = (std.io.getStdIn().reader().readUntilDelimiterAlloc(allocator, '\n', std.math.maxInt(usize)) catch |e| switch (e) {
            error.EndOfStream => {
                warn("=Console Ending=\n", .{});
                return;
            },
            else => return e,
        });
        try event_queue.push(Job{ .handle_stdin_line = .{ .buffer = line } });
    }
}

fn print_nng_sockaddr(sockaddr: c.nng_sockaddr) ![]u8 {
    const fam = sockaddr.s_family;

    const ipv4 = sockaddr.s_in;

    var addr = ipv4.sa_addr;
    const addr_ptr = @ptrCast([*]u8, &addr);
    const buffer = try std.fmt.allocPrint(allocator, "{} {} {} {}:{}", .{ addr_ptr[0], addr_ptr[1], addr_ptr[2], addr_ptr[3], ipv4.sa_port });
    return buffer;
}

fn handle_response(msg: *c.nng_msg, guid: u64) !void {
    var body = msg_to_slice(msg);

    // Ping?
    var sockaddr: c.nng_sockaddr = undefined;
    std.mem.copy(u8, @ptrCast([*]u8, &sockaddr)[0..@sizeOf(c.nng_sockaddr)], body[0..@sizeOf(c.nng_sockaddr)]);
    warn("my sock was: {} {}\n", .{ sockaddr.s_family, sockaddr.s_in });
    body = body[@sizeOf(c.nng_sockaddr)..];

    var response_id: ID = undefined;
    warn("body: {}\n", .{body});
    std.mem.copy(u8, response_id[0..], body);
    warn("response id: {}\n", .{response_id});

    var conn = try connection_by_guid(guid);
    warn("conn[{}] {}\n", .{ guid, conn });
    conn.id = response_id;

    warn("set conn to {}\n", .{conn});
}

fn handle_request(operand: Operand, msg: *c.nng_msg, guid: u64) !void {
    var slice = msg_to_slice(msg);
    switch (operand) {
        .GetID => {
            var reply_msg: ?*c.nng_msg = undefined;
            try nng_ret(c.nng_msg_alloc(&reply_msg, 0));
            try nng_ret(c.nng_msg_append_u64(reply_msg, guid));

            const pipe = c.nng_msg_get_pipe(msg);
            var sockaddr: c.nng_sockaddr = undefined;
            try nng_ret(c.nng_pipe_get_addr(pipe, c.NNG_OPT_REMADDR, &sockaddr));
            const buf = try print_nng_sockaddr(sockaddr);
            try nng_ret(c.nng_msg_append(reply_msg, @ptrCast(*c_void, &sockaddr), @sizeOf(c.nng_sockaddr)));
            try nng_ret(c.nng_msg_append(reply_msg, @ptrCast(*c_void, my_id[0..]), my_id.len));

            try event_queue.push(Job{ .reply = .{ .guid = guid, .msg = reply_msg.? } });
        },
    }
}

fn msg_to_slice(msg: *c.nng_msg) []u8 {
    const len = c.nng_msg_len(msg);
    const body = @ptrCast([*]u8, c.nng_msg_body(msg));
    return body[0..len];
}

const Job = union(enum) {
    ping_id: PingID,
    store: Store,
    get: Get,
    handle_request: HandleRequest,
    bootstrap: Bootstrap,
    connect: Connect,
    handle_response: HandleResponse,
    reply: Reply,
    handle_stdin_line: HandleStdinLine,

    fn work(self: *Job) !void {
        warn("job: {}\n", .{self});

        switch (self.*) {
            .ping_id => {
                warn("Ping: {}\n", .{self.ping_id});
                const guid = self.ping_id.guid;
                var conn = connection_by_guid(guid);

                warn("finding guid\n", .{});
                warn("n outgoing: {}\n", .{outgoing_workers.items.len});
                for (outgoing_workers.items) |out_worker| {
                    warn("out_worker {}\n", .{out_worker});
                    if (out_worker.accepting() and out_worker.guid == guid) {
                        warn("send to guid: {}\n", .{guid});

                        var msg: ?*c.nng_msg = undefined;
                        try nng_ret(c.nng_msg_alloc(&msg, 0));

                        try nng_ret(c.nng_msg_append_u32(msg, @enumToInt(Operand.GetID)));
                        try nng_ret(c.nng_msg_append_u64(msg, guid));

                        out_worker.send(msg.?);

                        // ptrCast(*c_void, d);
                        // const r2 = c.nng_msg_append();
                        return;
                    }
                }

                // If we get here nothing was sent, reschedule
                warn("reschedule\n", .{});
                try event_queue.push(self.*);
            },
            .store => {
                warn("store\n", .{});
                const key = self.store.key;
                const value = self.store.value;
                if (in_my_range(key)) //store here
                {
                    try database.put(key, value);
                } else {}
            },
            .get => {
                warn("get {}\n", .{self.get});
            },
            .handle_request => {
                warn("handle request\n", .{});
                const operand = self.handle_request.operand;
                const guid = self.handle_request.guid;
                var msg = self.handle_request.msg;

                try handle_request(operand, msg, guid);
            },
            .bootstrap => {
                warn("bootstrap: {}\n", .{known_addresses.items});
                var n = self.bootstrap.n;
                if (known_addresses.items.len < n)
                    n = known_addresses.items.len;

                var i: usize = 0;
                while (i < n) : (i += 1) {
                    var address = known_addresses.items[i];
                    try event_queue.push(Job{ .connect = .{ .address = address } });
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

                try routing_table.append(conn);

                // Create a worker
                warn("connect on socket: {}\n", .{conn.socket});
                var out_worker = try OutWork.alloc(conn.socket);
                out_worker.guid = conn.guid;
                try outgoing_workers.append(out_worker);

                try event_queue.push(Job{ .ping_id = .{ .guid = conn.guid } });
            },
            .reply => {
                warn("reply\n", .{});

                const guid = self.reply.guid;
                const msg = self.reply.msg;
                warn("guid {}, msg: {}\n", .{ guid, msg });
                for (incoming_workers) |w| {
                    if (w.guid == guid and w.state == .Wait) {
                        warn("replying\n", .{});
                        w.send(msg);
                        break;
                    }
                } else {
                    warn("Couldn't reply, guid: {}, workers: {}\n", .{ guid, incoming_workers });
                }
            },

            .handle_response => {
                const guid = self.handle_response.guid;
                const msg = self.handle_response.msg;
                warn("got: {}\n", .{self.handle_response});
                try handle_response(msg, guid);
            },
            .handle_stdin_line => {
                const buf = self.handle_stdin_line.buffer;
                warn("handle: {s}\n", .{buf});
                const space = std.mem.lastIndexOf(u8, buf, " ");
                if (space) |idx| {
                    const key = buf[0..idx];
                    const hash = calculate_hash(key);
                    const value = buf[idx + 1 ..];
                    warn("val: {s}:{s}\n", .{ key, value });
                    try event_queue.push(Job{ .store = .{ .key = hash, .value = value, .guid = 0 } });
                } else {
                    const key = buf;
                    const hash = calculate_hash(key);

                    try event_queue.push(Job{ .get = .{ .key = hash, .guid = 0 } });

                    warn("get: {s}\n", .{buf});
                }
            },
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

fn xor(id1: ID, id2: ID) ID {
    var result: ID = id1;
    for (result) |r, i| {
        result[i] = r ^ id2[i];
    }
    return result;
}

fn less(id1: ID, id2: ID) bool {
    return std.mem.order(u8, id1[0..], id2[0..]) == .lt;
}

fn in_my_range(id: ID) bool {
    var dist = xor(my_id, id);
    return less(id, closest_distance);
}

fn calculate_hash(data: []const u8) ID {
    var result: ID = undefined;
    crypto.hash.Blake3.hash(data, result[0..], .{});
    return result;
}

fn rand_id() ID {
    var id: ID = undefined;
    rng.random.bytes(id[0..]);
    return id;
}

fn nng_ret(code: c_int) !void {
    if (code != 0) {
        std.debug.warn("nng_err: {}\n", .{@ptrCast([*]const u8, c.nng_strerror(code))});
        return error.NNG;
    }
}

fn nng_append_array(msg: *c.nng_msg, buf: []const u8) !void {
    try nng_ret(c.nng_msg_append_u64(@intCast(u64, buf.len)));
}

fn nng_append(msg: *c.nng_msg, buf: anytype) !void {
    try nng_ret(c.nng_msg_append(msg, @ptrCast(*c_void, &buf), @sizeOf(buf)));

    try nng_ret(c.nng_msg_append(@intCast(u64, buf.len)));
}

fn init() !void {
    warn("Init\n", .{});
    my_id = rand_id();
    warn("My ID: {s}", .{my_id});
    std.mem.set(u8, closest_distance[0..], 0);

    event_thread = try Thread.spawn({}, event_queue_threadfunc);
    timer_thread = try Thread.spawn({}, timer_threadfunc);
    read_lines_thread = try Thread.spawn({}, read_lines);
}

// All operand imply a ID argument
// ID can refer to a peer, or item, depending on operand
// Some arguments have an additional number
const Operand = enum {
    GetID, //get ID of connecting node
    // GetMessage, //get general message. Arg is peer ID
    // GetPrevPeer,
    // GetNextPeer,
    // GetPrevItem, //number can be supplied to get more than one
    // GetNextItem, //number can be supplied to get more than one
    // GetItem, //retrieve an item
    // Store, // Store command -> check hash to be sure.
};

const InWork = struct {
    const State = enum {
        Init,
        Send,
        Recv,
        Wait,
    };

    state: State,
    aio: ?*c.nng_aio,
    msg: ?*c.nng_msg,
    ctx: c.nng_ctx,
    guid: Guid,

    pub fn toOpaque(w: *InWork) *c_void {
        return @ptrCast(*c_void, w);
    }

    pub fn fromOpaque(o: ?*c_void) *InWork {
        return @ptrCast(*InWork, @alignCast(@alignOf(*InWork), o));
    }

    pub fn send(w: *InWork, msg: *c.nng_msg) void {
        c.nng_aio_set_msg(w.aio, msg);
        c.nng_ctx_send(w.ctx, w.aio);
        w.state = .Send;
    }

    pub fn alloc(sock: c.nng_socket) !*InWork {
        var o = c.nng_alloc(@sizeOf(InWork));
        var w = InWork.fromOpaque(o);

        try nng_ret(c.nng_aio_alloc(&w.aio, inWorkCallback, w));

        try nng_ret(c.nng_ctx_open(&w.ctx, sock));

        w.state = State.Init;
        return w;
    }
};

fn ceil_log2(n: usize) usize {
    if (n == 0)
        return 0;
    return @floatToInt(usize, std.math.log2(@intToFloat(f64, n)));
}

// unique id for message work
var root_guid: Guid = 1234;
fn get_guid() Guid {
    const order = @import("builtin").AtomicOrder.Monotonic;
    var val = @atomicRmw(u64, &root_guid, .Add, 1, order);
    return val;
}

//thread to periodically queue work

fn timer_threadfunc(context: void) !void {
    warn("Timer thread\n", .{});
    while (true) {
        c.nng_msleep(3000);
    }
}

fn inWorkCallback(arg: ?*c_void) callconv(.C) void {
    warn("inwork callback\n", .{});
    const work = InWork.fromOpaque(arg);
    switch (work.state) {
        .Init => {
            c.nng_ctx_recv(work.ctx, work.aio);
            work.state = .Recv;
        },
        .Send => {
            c.nng_ctx_recv(work.ctx, work.aio);
            work.state = .Recv;
        },

        .Recv => {
            nng_ret(c.nng_aio_result(work.aio)) catch {
                work.state = .Init;
                return;
            };

            const msg = c.nng_aio_get_msg(work.aio);

            var operand = blk: {
                var int_operand: u32 = 0;
                nng_ret(c.nng_msg_trim_u32(msg, &int_operand)) catch {
                    warn("Failed to read operand\n", .{});
                    return;
                };
                break :blk @intToEnum(Operand, @intCast(@TagType(Operand), int_operand));
            };

            var guid: Guid = 0;
            nng_ret(c.nng_msg_trim_u64(msg, &guid)) catch return;

            // set worker up for reply
            work.guid = guid;
            work.state = InWork.State.Wait;

            event_queue.push(Job{ .handle_request = .{ .operand = operand, .guid = guid, .msg = msg.? } }) catch |e| {
                warn("error: {}\n", .{e});
            };

            // Put this work in a callback!
        },

        .Wait => {},

        // InWork.State.Send => {
        //     const r = c.nng_aio_result(work.aio);
        //     if (r != 0) {
        //         c.nng_msg_free(work.msg);
        //         fatal("nng_ctx_send", r);
        //     }
        //     work.state = InWork.State.Recv;
        //     c.nng_ctx_recv(work.ctx, work.aio);
        // },
    }
}

const OutWork = struct {
    const State = enum {
        Unconnected, // Unconnected
        Ready, // Ready to accept
        Send,
        Wait, // Waiting for reply
    };

    state: State = .Unconnected,
    aio: ?*c.nng_aio,
    ctx: c.nng_ctx,

    id: ID, //ID of connected node
    guid: Guid = 0, //Internal processing id

    pub fn toOpaque(w: *OutWork) *c_void {
        return @ptrCast(*c_void, w);
    }

    pub fn fromOpaque(o: ?*c_void) *OutWork {
        return @ptrCast(*OutWork, @alignCast(@alignOf(*OutWork), o));
    }

    pub fn accepting(w: *OutWork) bool {
        return w.state == .Ready;
    }

    pub fn send(w: *OutWork, msg: *c.nng_msg) void {
        w.state = .Send;
        c.nng_aio_set_msg(w.aio, msg);
        c.nng_ctx_send(w.ctx, w.aio);
    }

    pub fn alloc(sock: c.nng_socket) !*OutWork {
        var o = c.nng_alloc(@sizeOf(OutWork));
        if (o == null) {
            try nng_ret(2); // c.NNG_ENOMEM
        }

        var w = OutWork.fromOpaque(o);

        try nng_ret(c.nng_aio_alloc(&w.aio, outWorkCallback, w));

        try nng_ret(c.nng_ctx_open(&w.ctx, sock));

        //set initial id to 0, will be filled in by request
        std.mem.set(u8, w.id[0..], 0);
        w.state = State.Ready;

        return w;
    }
};

fn outWorkCallback(arg: ?*c_void) callconv(.C) void {
    warn("outwork callback\n", .{});

    const work = OutWork.fromOpaque(arg);
    switch (work.state) {
        .Ready => {},
        .Send => {
            c.nng_ctx_recv(work.ctx, work.aio);
            work.state = .Wait;
        },

        .Wait => {
            nng_ret(c.nng_aio_result(work.aio)) catch return;

            var msg = c.nng_aio_get_msg(work.aio);
            var guid: Guid = 0;
            nng_ret(c.nng_msg_trim_u64(msg, &guid)) catch {
                warn("couldn't trim guid\n", .{});
            };
            warn("read guid: {}\n", .{guid});
            event_queue.push(Job{ .handle_response = .{ .guid = guid, .msg = msg.? } }) catch unreachable;
        },

        .Unconnected => {
            warn("Callback on Unconnected\n", .{});
        },
    }
}

const InternalWork = struct {
    const State = enum {};
};

fn sockToString(addr: c.nng_sockaddr) [:0]u8 {
    if (addr.s_family == c.NNG_AF_INET) {
        var in_addr = addr.s_in.sa_addr;
        return fmt.allocPrint(allocator, "tcp://{}", .{in_addr});
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
        inWorkCallback(w.toOpaque());
    }

    try event_queue.push(Job{ .bootstrap = .{ .n = 4 } });

    event_thread.wait();
}
