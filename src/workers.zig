const std = @import("std");
const logger = @import("logger.zig");

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
const Connection = @import("connection.zig");

pub const InWork = struct {
    const State = enum {
        Init, //going to recv
        Recv, //waiting for a recv
        Wait, //waiting for processing to create response
        Error, //error happened
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
        Ready, // Ready to send out a message
        Send, // Message was sent, going to call recv
        Wait, // Waiting for reply after recv
        Error, //error happened
    };

    state: State = .Unconnected,
    aio: ?*c.nng_aio,
    ctx: c.nng_ctx,

    // id: ID, //ID of connected node
    guid: Guid = 0, //Internal processing id

    connection: *Connection,

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
        logger.log_fmt("sending out\n", .{});
        w.state = .Send;
        c.nng_aio_set_msg(w.aio, msg);
        c.nng_ctx_send(w.ctx, w.aio);
    }

    pub fn alloc(connection: *Connection) !*OutWork {
        var o = c.nng_alloc(@sizeOf(OutWork));
        if (o == null) {
            try nng_ret(c.NNG_ENOMEM);
        }

        var w = OutWork.fromOpaque(o);
        w.connection = connection;
        w.guid = defines.get_guid();

        // setup aio and context
        const timeout = 2000;
        try nng_ret(c.nng_aio_alloc(&w.aio, outWorkCallback, w));
        c.nng_aio_set_timeout(w.aio.?, timeout);
        try nng_ret(c.nng_ctx_open(&w.ctx, connection.socket));
        w.state = State.Ready;

        return w;
    }
};

pub fn inWorkCallback(arg: ?*c_void) callconv(.C) void {
    logger.log_fmt("inwork callback\n", .{});

    const work = InWork.fromOpaque(arg);

    nng_ret(c.nng_aio_result(work.aio)) catch {
        logger.log_fmt("error\n", .{});
        work.state = .Error;
        return;
    };

    switch (work.state) {
        .Error => {
            //disconnect
            logger.log_fmt("In worker Error state\n", .{});
        },
        .Init => {
            c.nng_ctx_recv(work.ctx, work.aio);
            work.state = .Recv;
        },

        .Recv => {
            const msg = c.nng_aio_get_msg(work.aio);

            var msg_guid: Guid = 0;
            nng_ret(c.nng_msg_trim_u64(msg, &msg_guid)) catch |e| {
                logger.log_fmt("Failed to trim incoming message: {}\n", .{e});
                work.state = .Error;
                return;
            };

            // set worker up for response
            work.guid = msg_guid;
            work.state = .Wait;

            // We deserialise the message in a request
            const request = deserialise_msg(Request, msg.?) catch |e| {
                logger.log_fmt("Failed to deserialise incoming request: {}\n", .{e});
                work.state = .Error;
                return;
            };

            // We handle the msg; we still pass on the nng_msg,
            // in case we need to query extra information
            enqueue(Job{ .handle_request = .{ .guid = msg_guid, .enveloped = request, .msg = msg.? } }) catch |e| {
                logger.log_fmt("error: {}\n", .{e});
            };
        },

        .Wait => {},
    }
}

fn outWorkCallback(arg: ?*c_void) callconv(.C) void {
    const work = OutWork.fromOpaque(arg);

    nng_ret(c.nng_aio_result(work.aio)) catch {
        logger.log_fmt("error\n", .{});
        work.state = .Error;
        return;
    };

    switch (work.state) {
        .Error => {
            logger.log_fmt("Outworker Error state\n", .{});
        },
        .Ready => {},
        .Send => {
            logger.log_fmt("out callback, calling recv\n", .{});

            c.nng_ctx_recv(work.ctx, work.aio);
            work.state = .Wait;
        },

        .Wait => {
            var msg = c.nng_aio_get_msg(work.aio);
            var guid: Guid = 0;

            nng_ret(c.nng_msg_trim_u64(msg, &guid)) catch {
                logger.log_fmt("couldn't trim guid\n", .{});
                work.state = .Error;
                return;
            };

            logger.log_fmt("outworker: response guid: {}\n", .{guid});
            const response = deserialise_msg(Response, msg.?) catch {
                logger.log_fmt("couldn't deserialise msg\n", .{});
                work.state = .Error;
                return;
            };

            // handle response
            enqueue(Job{ .handle_response = .{ .guid = guid, .enveloped = response, .msg = msg.? } }) catch unreachable;

            // We can send out a message again
            work.state = .Ready;
        },

        .Unconnected => {
            logger.log_fmt("Callback on Unconnected\n", .{});
        },
    }
}
