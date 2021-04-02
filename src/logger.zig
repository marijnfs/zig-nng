const std = @import("std");
const defines = @import("defines.zig");
const allocator = defines.allocator;

var log_file: std.fs.File = undefined;

pub fn log(t: [:0]const u8) void {
    const bytes_written = log_file.writeAll(t) catch unreachable;
}

pub fn log_fmt(comptime template: anytype, args: anytype) void {
    const result = std.fmt.allocPrint(allocator, template, args) catch unreachable;
    defer allocator.free(result);

    const bytes_written = log_file.writeAll(result) catch unreachable;
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
