// Datamodel for workings of the program
const std = @import("std");
const node = @import("node.zig");
const utils = @import("utils.zig");
const defines = @import("defines.zig");
const allocator = defines.allocator;

const Guid = defines.Guid;
const ID = defines.ID;

pub var messages = std.ArrayList([]u8).init(allocator);

// Guid filter
pub var hash_seen = std.AutoHashMap(ID, bool).init(allocator);

pub fn add_message(message: []u8) !void {
    const hash = utils.calculate_hash(message);
    if (hash_seen.get(hash)) |seen| {
        return;
    }
    try hash_seen.put(hash, true);
    try messages.append(try std.mem.dupe(defines.allocator, u8, message));
}
