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

const N_INCOMING_WORKERS = 16;
const N_OUTGOING_WORKERS = 16;

// We are currently going for 64kb blocks
const BIT_PER_BLOCK = 16;
const BLOCK_SIZE = 1 << BIT_PER_BLOCK;
const ROUTING_TABLE_SIZE = 16;

const Block = []u8;

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
const routing_table = [ROUTING_TABLE_SIZE]Connection;

var incoming_workers: [N_INCOMING_WORKERS]*InWork = undefined;
var outgoing_workers: std.ArrayList(*OutWork) = undefined;

var main_socket: c.nng_socket = undefined;

var rng = std.rand.DefaultPrng.init(0);

const Connection = struct {
    id: ID,
    socket: c.nng_socket,
};

const PingID = struct {
    address: [:0]const u8,
};

const SendMessage = struct {
    msg: *c.nng_msg,
    id: ID,
    uuid: u64, //internal processing id
};

const Job = union(enum) {
    ping_id: PingID,
    check_connections: void,

    fn work(self: *Job) void {
        switch (self.*) {
            .ping_id => {
                warn("Ping: {s}\n", .{self.ping_id});
            },
            .check_connections => {},
        }
    }
};

fn event_queue_threadfunc(context: void) void {
    while (true) {
        if (event_queue.pop()) |*job| {
            job.work();
        } else {
            warn("sleeping\n", .{});
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
    return std.mem.order(u8, id1, id2) == .lt;
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
    GetMessage, //get general message. Arg is peer ID
    GetPrevPeer,
    GetNextPeer,
    GetPrevItem, //number can be supplied to get more than one
    GetNextItem, //number can be supplied to get more than one
    GetItem, //retrieve an item
    Store, // Store command -> check hash to be sure.
};

const InWork = struct {
    const State = enum {
        Init,
        Recv,
        Wait,
        Send,
    };

    state: State,
    aio: ?*c.nng_aio,
    msg: ?*c.nng_msg,
    ctx: c.nng_ctx,

    pub fn toOpaque(w: *InWork) *c_void {
        return @ptrCast(*c_void, w);
    }

    pub fn fromOpaque(o: ?*c_void) *InWork {
        return @ptrCast(*InWork, @alignCast(@alignOf(*InWork), o));
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

// unique id for message work
var guid: u64 = 0;
fn get_guid() u64 {
    const order = @import("builtin").AtomicOrder.Monotonic;
    var val = @atomicRmw(u64, &guid, .Add, 1, order);
    return guid;
}

//thread to periodically queue work

fn timer_threadfunc(context: void) !void {
    warn("Timer thread\n", .{});
    while (true) {
        c.nng_msleep(3000);
        try event_queue.push(Job{ .ping_id = .{ .address = "update" } });
        warn("adding work\n", .{});
        warn("guid: {}\n", .{get_guid()});
    }
}

fn inWorkCallback(arg: ?*c_void) callconv(.C) void {
    const work = InWork.fromOpaque(arg);
    switch (work.state) {
        InWork.State.Init => {
            work.state = InWork.State.Recv;
            c.nng_ctx_recv(work.ctx, work.aio);
        },

        InWork.State.Recv => {
            const r1 = c.nng_aio_result(work.aio);
            if (r1 != 0) {
                fatal("nng_ctx_recv", r1);
            }

            const msg = c.nng_aio_get_msg(work.aio);

            var operand: u32 = undefined;
            const r2 = c.nng_msg_trim_u32(msg, &operand);
            if (r2 != 0) {
                c.nng_msg_free(msg);
                c.nng_ctx_recv(work.ctx, work.aio);
                return;
            }

            warn("Operand: {}\n", .{operand});

            work.msg = msg;
            work.state = InWork.State.Wait;

            // Put this work in a callback!
        },

        InWork.State.Wait => {
            c.nng_aio_set_msg(work.aio, work.msg);
            work.msg = null;
            work.state = InWork.State.Send;
            c.nng_ctx_send(work.ctx, work.aio);
        },

        InWork.State.Send => {
            const r = c.nng_aio_result(work.aio);
            if (r != 0) {
                c.nng_msg_free(work.msg);
                fatal("nng_ctx_send", r);
            }
            work.state = InWork.State.Recv;
            c.nng_ctx_recv(work.ctx, work.aio);
        },
    }
}

const OutWork = struct {
    const State = enum {
        Unconnected, // Unconnected
        Ready, // Ready to accept
        Waiting, // Waiting for reply
    };

    state: State = Unconnected,
    aio: ?*c.nng_aio,
    msg: ?*c.nng_msg,
    ctx: c.nng_ctx,

    id: ID, //ID of connected node
    guid: i64 = 0, //Internal processing id

    pub fn toOpaque(w: *OutWork) *c_void {
        return @ptrCast(*c_void, w);
    }

    pub fn fromOpaque(o: ?*c_void) *OutWork {
        return @ptrCast(*OutWork, @alignCast(@alignOf(*OutWork), o));
    }

    pub fn alloc(sock: c.nng_socket, id: ID, inWork: ?*InWork, arg: i64) *OutWork {
        var o = c.nng_alloc(@sizeOf(OutWork));
        if (o == null) {
            fatal("nng_alloc", 2); // c.NNG_ENOMEM
        }
        var w = OutWork.fromOpaque(o);

        w.state = State.Init;
        w.id = id;
        w.arg = arg;

        const r1 = c.nng_aio_alloc(&w.aio, outWorkCallback, w);
        if (r1 != 0) {
            fatal("nng_aio_alloc", r1);
        }

        const r2 = c.nng_ctx_open(&w.ctx, sock);
        if (r2 != 0) {
            fatal("nng_ctx_open", r2);
        }

        return w;
    }
};

fn outWorkCallback(arg: ?*c_void) callconv(.C) void {
    const work = OutWork.fromOpaque(arg);
    switch (work.state) {
        OutWork.State.Init => {},

        OutWork.State.Send => {},

        OutWork.State.Wait => {},

        OutWork.State.Recv => {},
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

    try known_addresses.append(address);

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

    try event_queue.push(Job{ .ping_id = .{ .address = "test" } });

    warn("end", .{});
    event_thread.wait();
}
