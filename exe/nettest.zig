const std = @import("std");
const net = @import("net");

const allocator = std.heap.page_allocator;

pub const io_mode = .evented;

pub fn main() !void {
    try net.init();

    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.warn("usage: {s} <post> <target>, eg target=tcp://localhost:1234 \n", .{args[0]});
        std.os.exit(1);
    }

    var my_port = try std.fmt.parseInt(u16, args[1], 10);

    var server_frame = async net.server_loop(my_port);

    if (args.len > 2) {
        var endpoints = try net.get_endpoint_list(args[2], 2001);
        if (endpoints.len < 1) {
            return error.NoEndpoint;
        }
        var outward = try net.Connection.create(endpoints[0]);
        var connect_frame = async outward.connect(endpoints[0]);

        std.debug.warn("Done\n", .{});
    }
}
