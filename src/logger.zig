const std = @import("std");
const defines = @import("defines.zig");
const allocator = defines.allocator;
const display = @import("display.zig");

var log_file: std.fs.File = undefined;

pub fn log(t: [:0]const u8) void {
    _ = log_file.writeAll(t) catch unreachable;
    _ = display.error_writer().write(t) catch unreachable;
}

pub fn log_fmt(comptime template: anytype, args: anytype) void {
    const error_fmt = std.fmt.allocPrint(allocator, template, args) catch unreachable;
    defer allocator.free(error_fmt);

    _ = log_file.writeAll(error_fmt) catch unreachable;
    _ = display.error_writer().write(error_fmt) catch unreachable;
}

pub fn init_log() !void {
    log_file = try std.fs.cwd().createFile(
        "log_file.txt",
        .{ .read = true },
    );
}

fn deinit_log() void {
    log_file.close();
}
