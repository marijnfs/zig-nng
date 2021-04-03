// Datamodel for workings of the program
const std = @import("std");
const node = @import("node.zig");

const defines = @import("defines.zig");
const allocator = defines.allocator;

pub var messages = std.ArrayList([]u8).init(allocator);

pub fn add_message(message: []u8) !void {
    try messages.append(try std.mem.dupe(defines.allocator, u8, message));

    // //send message on
    // const guid = defines.get_guid();
    // try node.self_guids.put(guid, true);
    // try node.enqueue(node.Job{
    //     .broadcast_msg = .{
    //         .guid = guid,
    //         .enveloped = .{ .content = message },
    //     },
    // });
}
