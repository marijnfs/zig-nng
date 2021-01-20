const std = @import("std");
const ArrayList = std.ArrayList;
const AutoHashMap = std.AutoHashMap;
const Thread = std.Thread;
const AtomicQueue = @import("queue.zig").AtomicQueue;
const meta = std.meta;

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
var root_guid: Guid = undefined;

// Guid that will be used to signify self-id
var self_guid: Guid = undefined;

var my_id: ID = std.mem.zeroes(ID);
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
var known_addresses = std.ArrayList([:0]u8).init(allocator);

// Addresses to self
var self_addresses = std.StringHashMap(bool).init(allocator);

// Our routing table
var routing_table = std.AutoHashMap(ID, []u8).init(allocator);

// Our connections
var connections = std.ArrayList(*Connection).init(allocator);

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
        warn("self guid: {}", .{self_guid});
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

const GuidKeyValue = struct {
    guid: u64 = 0, //source of request
    key: ID,
    value: []u8 = undefined,
};

const Bootstrap = struct {
    n: usize,
};

const Connect = struct {
    address: [:0]const u8,
};

const RequestData = struct {
    id: ID = undefined, //recipient
    guid: Guid = 0, //internal processing id
    request: Request, msg: *c.nng_msg = undefined
};

const ResponseData = struct {
    id: ID = undefined, //recipient
    guid: Guid = 0, //internal processing id
    response: Response,
};

const HandleStdinLine = struct {
    buffer: []u8,
};

fn connection_by_guid(guid: Guid) !*Connection {
    for (connections.items) |conn| {
        if (conn.guid == guid) {
            return conn;
        }
    }
    return error.NotFound;
}

fn connection_by_nearest_id(id: ID) !*Connection {
    var nearest: ID = std.mem.zeroes(ID);
    var nearest_conn: *Connection = undefined;

    for (connections.items) |conn| {
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

fn print_nng_sockaddr(sockaddr: c.nng_sockaddr, with_port: bool) ![]u8 {
    const fam = sockaddr.s_family;

    if (fam == c.NNG_AF_INET) {
        const ipv4 = sockaddr.s_in;

        var addr = ipv4.sa_addr;
        const addr_ptr = @ptrCast([*]u8, &addr);
        const buffer = if (!with_port) try std.fmt.allocPrint(allocator, "{}.{}.{}.{}", .{ addr_ptr[0], addr_ptr[1], addr_ptr[2], addr_ptr[3], ipv4.sa_port }) else std.fmt.allocPrint(allocator, "{}.{}.{}.{}:{}", .{ addr_ptr[0], addr_ptr[1], addr_ptr[2], addr_ptr[3], ipv4.sa_port });
        return buffer;
    }
    if (fam == c.NNG_AF_INET6) {
        const ipv6 = sockaddr.s_in6;
        var addr = ipv6.sa_addr;
        const addr_ptr = @ptrCast([*]u8, &addr);
        const buffer = try std.fmt.allocPrint(allocator, "{x}{x}:{x}{x}:{x}{x}:{x}{x}:{x}{x}:{x}{x}:{x}{x}:{x}{x}:/{}", .{
            addr_ptr[0],  addr_ptr[1],  addr_ptr[2],  addr_ptr[3],  addr_ptr[4],
            addr_ptr[5],  addr_ptr[6],  addr_ptr[7],  addr_ptr[8],  addr_ptr[9],
            addr_ptr[10], addr_ptr[11], addr_ptr[12], addr_ptr[13], addr_ptr[14],
            addr_ptr[15], ipv6.sa_port,
        });
        return buffer;
    }

    return error.SockaddrPrintUnsupported;
}

fn handle_response(guid: u64, response: Response) !void {
    // var body = msg_to_slice(msg);
    var for_me: bool = guid == self_guid;

    if (for_me) {
        warn("message for me! {} {}", .{ guid, response });
    }

    switch (response) {
        .ping_id => {
            warn("got resp ping id {}\n", .{response.ping_id});
        },
    }

    // // Ping
    // var sockaddr: c.nng_sockaddr = undefined;
    // std.mem.copy(u8, @ptrCast([*]u8, &sockaddr)[0..@sizeOf(c.nng_sockaddr)], body[0..@sizeOf(c.nng_sockaddr)]);

    // var my_addr = try print_nng_sockaddr(sockaddr);
    // warn("my addr: {s}\n", .{my_addr});
    // body = body[@sizeOf(c.nng_sockaddr)..];

    // var response_id: ID = undefined;
    // warn("body: {}\n", .{body});
    // std.mem.copy(u8, response_id[0..], body);
    // warn("response id: {}\n", .{response_id});

    // var conn = try connection_by_guid(guid);
    // warn("conn[{}] {}\n", .{ guid, conn });
    // conn.id = response_id;

    // warn("set conn to {}\n", .{conn});
}

fn handle_request(guid: Guid, request: Request, msg: *c.nng_msg) !void {
    switch (request) {
        .ping_id => {
            warn("requesting pingid\n", .{});
            const pipe = c.nng_msg_get_pipe(msg);
            var sockaddr: c.nng_sockaddr = undefined;
            try nng_ret(c.nng_pipe_get_addr(pipe, c.NNG_OPT_REMADDR, &sockaddr));
            try event_queue.push(Job{ .send_response = .{ .guid = guid, .response = .{ .ping_id = .{ .id = my_id, .sockaddr = sockaddr } } } });
        },
    }
    // const tag = @as(@TagType(Request), request);
    // switch (tag) {
    //     .ping_id => {
    //             const pipe = c.nng_msg_get_pipe(msg);
    // var sockaddr: c.nng_sockaddr = undefined;
    // try nng_ret(c.nng_pipe_get_addr(pipe, c.NNG_OPT_REMADDR, &sockaddr));

    //         try event_queue.push(Job{ .send_response = .{ .guid = guid, .response = .{ .ping_id = .{. sockaddr = sockaddr} } } });
    //     },
    // }
}

fn msg_to_slice(msg: *c.nng_msg) []u8 {
    const len = c.nng_msg_len(msg);
    const body = @ptrCast([*]u8, c.nng_msg_body(msg));
    return body[0..len];
}

const Request = union(enum) {
    ping_id: struct {}
};

const PingId = struct {
    guid: Guid, //target connection guid
};

const Response = union(enum) {
    ping_id: struct { id: ID, sockaddr: c.nng_sockaddr },
};

fn enqueue(job: Job) !void {
    try event_queue.push(job);
}

fn deserialise_msg(comptime T: type, msg: *c.nng_msg) !T {
    var t: T = undefined;
    const info = @typeInfo(T);
    switch (info) {
        .Struct => {
            inline for (info.Struct.fields) |*field_info| {
                const name = field_info.name;
                const FieldType = field_info.field_type;
                if (comptime meta.trait.isIndexable(FieldType)) {
                    continue;
                }

                @field(&t, name) = try deserialise_msg(FieldType, msg);
            }
        },
        .Array => {
            const len = info.Array.size;
            const byteSize = @sizeOf(meta.Child(T)) * len;
            if (c.nng_msg_len(msg) < byteSize) {
                return error.MsgSmallerThanArray;
            }

            const bodyPtr = @ptrCast(*T, c.nng_msg_body(msg));
            std.mem.copy(u8, &t, bodyPtr);
            try nng_ret(c.nng_msg_trim(
                msg,
                @ptrCast(*c_void, &t),
                @sizeOf(T),
            ));
        },
        .Pointer => {
            if (comptime std.meta.trait.isSlice(info)) {
                try nng_ret(c.nng_msg_append_u64(msg, @intCast(u64, info.len)));
                try nng_ret(c.nng_msg_append(msg, @ptrCast(*c_void, &t), @sizeOf(meta.Child(T)) * t.len));
            } else {
                @compileError("Expected to serialise slice");
            }
        },
        .Union => {
            if (comptime info.Union.tag_type) |TagType| {
                // const TagType = @TagType(T);
                const active_tag = try deserialise_msg(TagType, msg);

                inline for (info.Union.fields) |field_info| {
                    if (@field(TagType, field_info.name) == active_tag) {
                        const name = field_info.name;
                        const FieldType = field_info.field_type;

                        @field(t, name) = try deserialise_msg(FieldType, msg);
                    }
                }
            } else { // c struct or general struct
                try nng_ret(c.nng_msg_append(msg, @ptrCast(*c_void, &t), @sizeOf(T)));
            }
        },
        .Enum => {
            t = blk: {
                var int_operand: u32 = 0;
                nng_ret(c.nng_msg_trim_u32(msg, &int_operand)) catch {
                    warn("Failed to read operand\n", .{});
                    return error.DeserialisationFail;
                };
                break :blk @intToEnum(T, @intCast(@TagType(T), int_operand));
            };
        },
        else => @compileError("Cannot deserialize " ++ @tagName(@typeInfo(T)) ++ " types (unimplemented)."),
    }
    return t;
}

fn serialise_msg(t: anytype, msg: *c.nng_msg) !void {
    const T = comptime @TypeOf(t);

    const info = @typeInfo(T);
    switch (info) {
        .Struct => {
            inline for (info.Struct.fields) |*field_info| {
                const name = field_info.name;
                const FieldType = field_info.field_type;
                try serialise_msg(@field(t, name), msg);
            }
        },
        .Array => {
            const len = info.Array.len;
            var tmp = t;
            try nng_ret(c.nng_msg_append(msg, @ptrCast(*c_void, &tmp), @sizeOf(meta.Child(T)) * len));
        },
        .Pointer => {
            if (comptime std.meta.trait.isSlice(info)) {
                try nng_ret(c.nng_msg_append_u64(msg, @intCast(u64, info.len)));
                try nng_ret(c.nng_msg_append(msg, @ptrCast(*c_void, &t), @sizeOf(meta.Child(T)) * t.len));
            } else {
                @compileError("Expected to serialise slice");
            }
        },
        .Union => {
            if (info.Union.tag_type) |TagType| {
                const active_tag = meta.activeTag(t);
                try serialise_msg(@as(@TagType(T), active_tag), msg);

                inline for (info.Union.fields) |field_info| {
                    if (@field(TagType, field_info.name) == active_tag) {
                        const name = field_info.name;
                        const FieldType = field_info.field_type;
                        try serialise_msg(@field(t, name), msg);
                    }
                }
            }
        },
        .Enum => {
            try nng_ret(c.nng_msg_append_u32(msg, @intCast(u32, @enumToInt(t))));
        },
        else => @compileError("Cannot serialize " ++ @tagName(@typeInfo(T)) ++ " types (unimplemented)."),
    }
}

const Job = union(enum) {
    connect: Connect,
    store: GuidKeyValue,
    get: GuidKeyValue,
    bootstrap: Bootstrap,

    handle_request: RequestData,
    handle_response: ResponseData,

    send_request: RequestData,
    send_response: ResponseData,

    handle_stdin_line: HandleStdinLine,

    fn work(self: *Job) !void {
        warn("job: {}\n", .{self});

        switch (self.*) {
            .send_request => {
                const guid = self.send_request.guid;
                var conn = connection_by_guid(guid);

                const request = self.send_request.request;

                var request_msg: ?*c.nng_msg = undefined;
                try nng_ret(c.nng_msg_alloc(&request_msg, 0));

                // First set the guid
                try nng_ret(c.nng_msg_append_u64(request_msg, guid));

                try serialise_msg(request, request_msg.?);

                warn("finding guid\n", .{});
                warn("n outgoing: {}\n", .{outgoing_workers.items.len});
                for (outgoing_workers.items) |out_worker| {
                    if (out_worker.accepting() and out_worker.guid == guid) {
                        warn("out_worker {}\n", .{out_worker});

                        warn("send to guid: {}\n", .{guid});

                        out_worker.send(request_msg.?);

                        return;
                    }
                }

                // If we get here nothing was sent, reschedule
                warn("reschedule\n", .{});
                try enqueue(self.*);
            },
            .send_response => {
                warn("response\n", .{});

                const guid = self.send_response.guid;
                const response = self.send_response.response;

                var response_msg: ?*c.nng_msg = undefined;
                try nng_ret(c.nng_msg_alloc(&response_msg, 0));

                // First set the guid
                try nng_ret(c.nng_msg_append_u64(response_msg, guid));

                try serialise_msg(response, response_msg.?);

                warn("guid {}, msg: {}\n", .{ guid, response_msg });
                for (incoming_workers) |w| {
                    if (w.guid == guid and w.state == .Wait) {
                        warn("responseing\n", .{});
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
                    try database.put(key, value);
                } else {}
            },
            .get => {
                warn("get {}\n", .{self.get});
            },
            .handle_request => {
                warn("handle request\n", .{});
                const guid = self.handle_request.guid;
                const request = self.handle_request.request;
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

                try enqueue(Job{ .send_request = .{ .guid = conn.guid, .request = .{ .ping_id = .{} } } });
            },

            .handle_response => {
                const guid = self.handle_response.guid;
                const response = self.handle_response.response;
                warn("got: {}\n", .{self.handle_response});
                try handle_response(guid, response);
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
                    try enqueue(Job{ .store = .{ .key = hash, .value = value, .guid = 0 } });
                } else {
                    const key = buf;
                    const hash = calculate_hash(key);

                    try enqueue(Job{ .get = .{ .key = hash, .guid = 0 } });

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
    root_guid = rng.random.int(u64);
    self_guid = get_guid();

    warn("Init\n", .{});
    my_id = rand_id();
    warn("My ID: {x}", .{my_id});
    std.mem.set(u8, nearest_ID[0..], 0);

    event_thread = try Thread.spawn({}, event_queue_threadfunc);
    timer_thread = try Thread.spawn({}, timer_threadfunc);
    read_lines_thread = try Thread.spawn({}, read_lines);
}

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

            var guid: Guid = 0;
            nng_ret(c.nng_msg_trim_u64(msg, &guid)) catch unreachable;

            // set worker up for response
            work.guid = guid;
            work.state = InWork.State.Wait;

            // We deserialise the message in a request
            const request = deserialise_msg(Request, msg.?) catch unreachable;

            // We still add the msg, in case we need to query extra information
            enqueue(Job{ .handle_request = .{ .guid = guid, .request = request, .msg = msg.? } }) catch |e| {
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
        Wait, // Waiting for response
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

            warn("response msg size: {}\n", .{c.nng_msg_len(msg)});

            nng_ret(c.nng_msg_trim_u64(msg, &guid)) catch {
                warn("couldn't trim guid\n", .{});
            };
            warn("read guid: {}\n", .{guid});

            const response = deserialise_msg(Response, msg.?) catch unreachable;

            enqueue(Job{ .handle_response = .{ .guid = guid, .response = response } }) catch unreachable;
            work.state = .Ready;
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
