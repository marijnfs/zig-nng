const std = @import("std");
const defines = @import("defines.zig");
const allocator = defines.allocator;

var log_file: std.fs.File = undefined;

pub fn log(t: [:0]const u8) !void {
    const bytes_written = try log_file.writeAll(t);
}

pub fn log_fmt(comptime template: anytype, args: anytype) !void {
    const result = try std.fmt.allocPrint(allocator, template, args);
    defer allocator.free(result);

    const bytes_written = try log_file.writeAll(result);
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
