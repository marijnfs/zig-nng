const std = @import("std");
const net = @import("net");

pub const io_mode = .evented;

pub fn main() !void {
    try net.init();
    std.debug.warn("Done\n", .{});
}
