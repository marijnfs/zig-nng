// Datamodel for workings of the program
const std = @import("std");
const node = @import("node.zig");

const defines = @import("defines.zig");
const allocator = defines.allocator;

pub var messages = std.ArrayList([]u8).init(allocator);

pub fn add_message(message: []u8) !void {
    try messages.append(try std.mem.dupe(defines.allocator, u8, message));
}
