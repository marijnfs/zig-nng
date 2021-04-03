const std = @import("std");
const zbox = @import("zbox");
const page_allocator = std.heap.page_allocator;
const model = @import("model.zig");
const node = @import("node.zig");

var display_thread: *std.Thread = undefined;
var canvas: zbox.Buffer = undefined;
var box: zbox.Buffer = undefined;

fn process_key(cell: []const u8) void {
    if (cell.len > 1) {
        return;
    }

    if (cell[0] >= 'a' or cell[0] <= 'z') {}
}

pub fn start_display_thread() !void {
    display_thread = try std.Thread.spawn(display_loop, process_key);
}

pub fn deinit() !void {
    const size = try zbox.size();
    try canvas.resize(size.height, size.width);
    canvas.clear();
    try zbox.push(canvas);

    zbox.deinit();
}

pub fn draw() !void {
    // update the size of canvas buffer
    const size = try zbox.size();
    try canvas.resize(size.height, size.width);

    box.clear();
    box.fill(zbox.Cell{ .char = '-' });
    var cursor = box.wrappedCursorAt(0, 0);
    var writer = cursor.writer();

    for (model.messages.items) |line| {
        try writer.print("{s}\n", .{line});
    }

    canvas.clear();
    canvas.blit(box, 5, 5);

    try zbox.push(canvas);
}

pub fn display_loop(context: fn callback([]const u8) void) !void {
    var alloc = page_allocator;

    // initialize the zbox with stdin/out
    try zbox.init(alloc);
    defer zbox.deinit();

    // die on ctrl+C
    try zbox.handleSignalInput();

    //setup our drawing buffer
    var size = try zbox.size();

    canvas = try zbox.Buffer.init(alloc, size.height, size.width);
    defer canvas.deinit();

    box = try zbox.Buffer.init(alloc, 50, 50);
    defer box.deinit();

    while (true) {
        var event = try zbox.nextEvent();
        switch (event.?) {
            .tick => {
                continue;
            },
            .other => |other| {
                node.enqueue(node.Job{ .process_key = other }) catch unreachable;
            },
            .up => {},
            .down => {},
            .left => {},
            .right => {},
            .escape => {
                node.enqueue(node.Job{ .shutdown = 0 }) catch unreachable;
            },
        }
    }
}

test "static anal" {
    std.meta.refAllDecls(@This());
}
