const std = @import("std");
const c = @import("c.zig").c;

fn fatal(msg: []const u8, code: c_int) void {
    // TODO: std.fmt should accept [*c]const u8 for {s} format specific, should not require {s}
    // in this case?
    std.debug.warn("{}: {}\n", .{ msg, @ptrCast([*]const u8, c.nng_strerror(code)) });
    std.os.exit(1);
}

const Work = extern struct {
    const State = extern enum {
        Init,
        Recv,
        Wait,
        Send,
    };

    state: State,
    aio: ?*c.nng_aio,
    msg: ?*c.nng_msg,
    ctx: c.nng_ctx,

    pub fn toOpaque(w: *Work) *c_void {
        return @ptrCast(*c_void, w);
    }

    pub fn fromOpaque(o: ?*c_void) *Work {
        return @ptrCast(*Work, @alignCast(@alignOf(*Work), o));
    }

    pub fn alloc(sock: c.nng_socket) *Work {
        var o = c.nng_alloc(@sizeOf(Work));
        if (o == null) {
            fatal("nng_alloc", 2); // c.NNG_ENOMEM
        }
        var w = Work.fromOpaque(o);

        const r1 = c.nng_aio_alloc(&w.aio, serverCallback, w);
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

fn serverCallback(arg: ?*c_void) callconv(.C) void {
    const work = Work.fromOpaque(arg);
    switch (work.state) {
        Work.State.Init => {},

        Work.State.Recv => {},

        Work.State.Wait => {},

        Work.State.Send => {},
    }
}

pub fn serve(comptime worker_count: comptime_int, address: [*]const u8) void {
    var sock: c.nng_socket = undefined;
    var works: [worker_count]*Work = undefined;

    const r1 = c.nng_rep0_open(&sock);
    if (r1 != 0) {
        fatal("nng_rep0_open", r1);
    }

    for (works) |*w| {
        w.* = Work.alloc(sock);
    }

    const r2 = c.nng_listen(sock, address, 0, 0);
    if (r2 != 0) {
        fatal("nng_listen", r2);
    }

    std.debug.warn("listening on {}\n", .{address});

    for (works) |w| {
        serverCallback(w.toOpaque());
    }

    while (true) {
        c.nng_msleep(3600 * 1000);
    }
}

const parallel_count = 128;

pub fn main() !void {
    var allocator = std.heap.c_allocator;
    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len <= 1) {
        std.debug.warn("usage: {} <url>\n", .{args[0]});
        std.os.exit(1);
    }

    const address = try std.cstr.addNullByte(allocator, args[1]);
    defer allocator.free(address);

    serve(parallel_count, address.ptr);
}
