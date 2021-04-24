const std = @import("std");
const logger = @import("logger.zig");

pub const c = @cImport({
    @cInclude("nng/nng.h");
    @cInclude("nng/protocol/reqrep0/req.h");
    @cInclude("nng/protocol/reqrep0/rep.h");
    @cInclude("nng/protocol/pair1/pair.h");

    @cInclude("nng/supplemental/util/platform.h");
});

pub fn nng_ret(code: c_int) !void {
    if (code != 0) {
        logger.log_fmt("nng_err: {s}\n", .{c.nng_strerror(code)});
        if (code == c.NNG_ETIMEDOUT)
            return error.NNG_ETIMEDOUT;
        return error.NNG;
    }
}

pub fn nng_msg_alloc() !?*c.nng_msg {
    var request_msg: ?*c.nng_msg = undefined;
    try nng_ret(c.nng_msg_alloc(&request_msg, 0));
    return request_msg;
}
