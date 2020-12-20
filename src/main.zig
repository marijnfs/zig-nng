const std = @import("std");
const testing = std.testing;

const c = @import("c.zig").c;

export fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    testing.expect(add(3, 7) == 10);
}

test "nng" {
    var sock: c.nng_socket = undefined;
    var r: c_int = undefined;

    r = c.nng_req0_open(&sock);
    if (r != 0) {
        // fatal("nng_req0_open", r);
    }
    defer _ = c.nng_close(sock);
}
