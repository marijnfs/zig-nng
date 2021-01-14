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
    id: ID,
    socket: c.nng_socket,
    address: [:0]const u8,
    n_workers: usize = 0,
    guid: Guid,

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
        std.mem.set(u8, self.id[0..], 0);
        self.address = address;
        self.guid = get_guid();
    }

    fn req_open(
        self: *Connection,
    ) !void {
        warn("req open {s}\n", .{self.address});
        var r: c_int = undefined;
        r = c.nng_req0_open(&self.socket);
        if (r != 0) {
            fatal("nng_req0_open", r);
            return error.Fail;
        }
    }

    fn rep_open(self: *Connection) !void {
        warn("rep open {s}\n", .{self.address});
        var r: c_int = undefined;
        r = c.nng_rep0_open(self.sock);
        if (r != 0) {
            fatal("nng_req0_open", r);
            return error.Fail;
        }
    }

    fn dial(self: *Connection) !void {
        warn("dialing {s}\n", .{self.address});
        var r: c_int = undefined;
        r = c.nng_dial(self.socket, self.address, 0, 0);
        if (r != 0) {
            fatal("nng_dial", r);
            return error.Fail;
        }
    }
};

const Store = struct {
    src_id: u64, //source of request
    id: ID,
    data: []u8,
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

fn connection_by_guid(guid: Guid) !*Connection {
    for (routing_table.items) |conn| {
        if (conn.guid == guid) {
            return conn;
        }
    }
    return error.NotFound;
}

const Job = union(enum) {
    ping_id: PingID,
    store: Store,
    handle_request: HandleRequest,
    bootstrap: Bootstrap,
    connect: Connect,
    handle_response: HandleResponse,
    reply: Reply,

    fn work(self: *Job) !void {
        warn("job: {}\n", .{self});

        switch (self.*) {
            .ping_id => {
                warn("Ping: {}\n", .{self.ping_id});
                const guid = self.ping_id.guid;
                var conn = connection_by_guid(guid);

                warn("n outgoig: {}\n", .{outgoing_workers.items.len});
                for (outgoing_workers.items) |out_worker| {
                    warn("out_worker {}\n", .{out_worker});
                    if (out_worker.accepting() and out_worker.guid == guid) {
                        warn("send to guid: {}\n", .{guid});

                        var msg: ?*c.nng_msg = undefined;
                        const r = c.nng_msg_alloc(&msg, 0);
                        if (r != 0) {
                            fatal("nng_msg_alloc", r);
                        }

                        const r2 = c.nng_msg_append_u32(msg, @enumToInt(Operand.GetID));
                        const r3 = c.nng_msg_append_u64(msg, guid);

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
                const data_id = self.store.id;
                if (in_my_range(data_id)) //store here
                {} else {
                    const src = self.store.src_id;
                }
            },
            .handle_request => {
                warn("handle request\n", .{});
                const operand = self.handle_request.operand;
                const guid = self.handle_request.guid;
                var msg = self.handle_request.msg;

                const len = c.nng_msg_len(msg);
                const body = @ptrCast([*]u8, c.nng_msg_body(msg));
                var body_slice = body[0..len];

                switch (operand) {
                    .GetID => {
                        var reply_msg: ?*c.nng_msg = undefined;
                        const r = c.nng_msg_alloc(&reply_msg, 0);
                        if (r != 0) {
                            fatal("nng_msg_alloc", r);
                        }

                        const r2 = c.nng_msg_append(reply_msg, @ptrCast(*c_void, my_id[0..]), my_id.len);

                        try event_queue.push(Job{ .reply = .{ .guid = guid, .msg = reply_msg.? } });
                    },
                }
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

                var address = self.connect.address;
                var conn = try Connection.alloc();
                conn.init(address);
                try conn.req_open();
                try conn.dial();

                try routing_table.append(conn);

                warn("connect on socket: {}\n", .{conn.socket});
                var out_worker = OutWork.alloc(conn.socket);
                out_worker.guid = conn.guid;
                try outgoing_workers.append(out_worker);

                try event_queue.push(Job{ .ping_id = .{ .guid = conn.guid } });
            },
            .reply => {
                warn("reply\n", .{});

                const guid = self.reply.guid;
                const msg = self.reply.msg;
                for (incoming_workers) |w| {
                    if (w.guid == guid and w.state == .Wait) {
                        warn("replying\n", .{});
                        w.send(msg);
                    }
                }
            },
            .handle_response => {
                warn("got: {}\n", .{self.handle_response});
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

fn hash(data: []const u8) ID {
    var result: ID = undefined;
    crypto.hash.Blake3.hash(data, result[0..], .{});
    return result;
}

fn rand_id() ID {
    var id: ID = undefined;
    rng.random.bytes(id[0..]);
    return id;
}

fn init() !void {
    warn("Init\n", .{});
    my_id = rand_id();
    std.mem.set(u8, closest_distance[0..], 0);

    event_thread = try Thread.spawn({}, event_queue_threadfunc);
    timer_thread = try Thread.spawn({}, timer_threadfunc);
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

    pub fn alloc(sock: c.nng_socket) *InWork {
        var o = c.nng_alloc(@sizeOf(InWork));
        if (o == null) {
            fatal("nng_alloc", 2); // c.NNG_ENOMEM
        }
        var w = InWork.fromOpaque(o);

        const r1 = c.nng_aio_alloc(&w.aio, inWorkCallback, w);
        if (r1 != 0) {
            fatal("nng_aio_alloc", r1);
        }

        const r2 = c.nng_ctx_open(&w.ctx, sock);
        if (r2 != 0) {
            fatal("nng_ctx_open", r2);
        }

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
        warn("some guid: {} ceil: {}\n", .{ get_guid(), ceil_log2(1) });
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
            const r1 = c.nng_aio_result(work.aio);
            if (r1 != 0) {
                fatal("nng_ctx_recv", r1);
            }

            const msg = c.nng_aio_get_msg(work.aio);

            var operand = blk: {
                var int_operand: u32 = 0;
                const r2 = c.nng_msg_trim_u32(msg, &int_operand);
                if (r2 != 0) {
                    c.nng_msg_free(msg);
                    return;
                }
                break :blk @intToEnum(Operand, @intCast(@TagType(Operand), int_operand));
            };

            var guid: Guid = 0;
            const r2 = c.nng_msg_trim_u64(msg, &guid);

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

    pub fn alloc(sock: c.nng_socket) *OutWork {
        var o = c.nng_alloc(@sizeOf(OutWork));
        if (o == null) {
            fatal("nng_alloc", 2); // c.NNG_ENOMEM
        }

        var w = OutWork.fromOpaque(o);

        const r1 = c.nng_aio_alloc(&w.aio, outWorkCallback, w);
        if (r1 != 0) {
            fatal("nng_aio_alloc", r1);
        }

        const r2 = c.nng_ctx_open(&w.ctx, sock);
        if (r2 != 0) {
            fatal("nng_ctx_open", r2);
        }

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
            const r1 = c.nng_aio_result(work.aio);
            if (r1 != 0) {
                fatal("nng_ctx_recv", r1);
            }

            const msg = c.nng_aio_get_msg(work.aio);
            var guid: Guid = 0;
            const r2 = c.nng_msg_trim_u64(msg, &guid);
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

fn fatal(msg: []const u8, code: c_int) void {
    // TODO: std.fmt should accept [*c]const u8 for {s} format specific, should not require {s}
    // in this case?
    std.debug.warn("{}: {}\n", .{ msg, @ptrCast([*]const u8, c.nng_strerror(code)) });
    unreachable;
    // std.os.exit(1);
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

    const r1 = c.nng_rep0_open(&main_socket);
    if (r1 != 0) {
        fatal("nng_rep0_open", r1);
    }

    for (incoming_workers) |*w| {
        w.* = InWork.alloc(main_socket);
    }

    const r2 = c.nng_listen(main_socket, address, 0, 0);
    if (r2 != 0) {
        fatal("nng_listen", r2);
    }

    warn("listening on {s}", .{address});
    for (incoming_workers) |w| {
        inWorkCallback(w.toOpaque());
    }

    try event_queue.push(Job{ .bootstrap = .{ .n = 4 } });

    event_thread.wait();
}
