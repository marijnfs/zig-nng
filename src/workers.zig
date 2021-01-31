const std = @import("std");
const warn = std.debug.warn;

const c = @import("c.zig").c;
const nng_ret = @import("c.zig").nng_ret;

const defines = @import("defines.zig");
const Guid = defines.Guid;
const ID = defines.ID;

const deserialise_msg = @import("serialise.zig").deserialise_msg;
const Request = @import("requests.zig").Request;
const Response = @import("responses.zig").Response;
const enqueue = @import("node.zig").enqueue;
const Job = @import("node.zig").Job;

pub const InWork = struct {
    const State = enum {
        Init,
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
        w.state = .Init;
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

pub const OutWork = struct {
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
        warn("sending out\n", .{});
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

pub fn inWorkCallback(arg: ?*c_void) callconv(.C) void {
    warn("inwork callback\n", .{});
    const work = InWork.fromOpaque(arg);
    switch (work.state) {
        .Init => {
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
            nng_ret(c.nng_msg_trim_u64(msg, &guid)) catch |e| {
                warn("Failed to trim incoming message: {}\n", .{e});
                work.state = .Init;
                return;
            };

            // set worker up for response
            work.guid = guid;
            work.state = .Wait;

            // We deserialise the message in a request
            const request = deserialise_msg(Request, msg.?) catch |e| {
                warn("Failed to deserialise incoming request: {}\n", .{e});
                work.state = .Init;
                return;
            };

            // We still add the msg, in case we need to query extra information
            enqueue(Job{ .handle_request = .{ .guid = guid, .enveloped = request, .msg = msg.? } }) catch |e| {
                warn("error: {}\n", .{e});
            };
        },

        .Wait => {},
    }
}

fn outWorkCallback(arg: ?*c_void) callconv(.C) void {
    const work = OutWork.fromOpaque(arg);
    warn("outwork callback {}\n", .{work});
    switch (work.state) {
        .Ready => {},
        .Send => {
            warn("out callback, calling recv\n", .{});

            c.nng_ctx_recv(work.ctx, work.aio);
            work.state = .Wait;
        },

        .Wait => {
            nng_ret(c.nng_aio_result(work.aio)) catch {
                warn("error\n", .{});
                work.state = .Ready;
                return;
            };

            var msg = c.nng_aio_get_msg(work.aio);
            var guid: Guid = 0;

            nng_ret(c.nng_msg_trim_u64(msg, &guid)) catch {
                warn("couldn't trim guid\n", .{});
                work.state = .Ready;
                return;
            };
            warn("read response guid: {}\n", .{guid});
            const response = deserialise_msg(Response, msg.?) catch unreachable;
            enqueue(Job{ .handle_response = .{ .guid = guid, .enveloped = response, .msg = msg.? } }) catch unreachable;
            work.state = .Ready;
        },

        .Unconnected => {
            warn("Callback on Unconnected\n", .{});
        },
    }
}
