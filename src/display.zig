const std = @import("std");
const zbox = @import("zbox");
const page_allocator = std.heap.page_allocator;
const model = @import("model.zig");
const node = @import("node.zig");
const logger = @import("logger.zig");

var display_thread: *std.Thread = undefined;
var canvas: zbox.Buffer = undefined;
var box: zbox.Buffer = undefined;
var error_box: zbox.Buffer = undefined;

const DrawMode = enum {
    Messages,
    Connection,
    FingerTable,
    KnownAddresses,
    Workers,
    NDrawModes,
};

var focus_row: usize = 0;

var draw_mode: DrawMode = .Messages;
var error_cursor = error_box.wrappedCursorAt(0, 0);

pub fn next_mode() void {
    var int_val = @intCast(usize, @enumToInt(draw_mode));
    int_val += 1;
    int_val = int_val % @intCast(usize, @enumToInt(DrawMode.NDrawModes));
    draw_mode = @intToEnum(DrawMode, @intCast(std.meta.Tag(DrawMode), int_val));
}

pub fn prev_mode() void {
    var int_val = @intCast(i64, @enumToInt(draw_mode));
    int_val -= 1;
    if (int_val < 0)
        int_val += @intCast(i64, @enumToInt(DrawMode.NDrawModes));
    draw_mode = @intToEnum(DrawMode, @intCast(std.meta.Tag(DrawMode), int_val));
}

pub fn start_display_thread() !void {
    display_thread = try std.Thread.spawn(display_loop, {});
}

pub fn error_writer() zbox.Buffer.Writer {
    var writer = error_cursor.writer();
    return writer;
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

    try writer.print("mode:{}\n", .{draw_mode});

    switch (draw_mode) {
        .Messages => {
            for (model.messages.items) |line| {
                try writer.print("{s}\n", .{line});
            }
        },
        .Connection => {
            try writer.print("My id: {s}, conn:\n", .{std.fmt.fmtSliceHexLower(node.my_id[0..])});
            for (node.connections.items) |connection| {
                try writer.print("addr:{s} id:{s}, n_workers:{} state:{}\n", .{ connection.address, std.fmt.fmtSliceHexLower(connection.id[0..]), connection.n_workers, connection.state });
            }
        },
        .KnownAddresses => {
            for (node.known_addresses.items) |addr| {
                try writer.print("addr:{s}\n", .{addr});
            }
        },
        .FingerTable => {
            var it = node.finger_table.iterator();
            while (it.next()) |finger| {
                const base_id = finger.key;
                const id = finger.value.id;
                if (finger.value.address) |address| {
                    try writer.print("base:{s} id:{s} addr:{s}\n", .{ std.fmt.fmtSliceHexLower(base_id[0..]), std.fmt.fmtSliceHexLower(id[0..]), address });
                } else {
                    try writer.print("base:{s} id:{s}\n", .{ std.fmt.fmtSliceHexLower(base_id[0..]), std.fmt.fmtSliceHexLower(base_id[0..]) });
                }
            }
        },
        .Workers => {
            for (node.outgoing_workers.items) |worker| {
                try writer.print("worker:{any}\n", .{worker});
            }
            _ = try writer.write("=====");
            for (node.incoming_workers.items) |worker| {
                try writer.print("in work:{any}\n", .{worker});
            }
        },
        .NDrawModes => {},
    }

    canvas.clear();
    canvas.blitFrom(box, .{
        .row_num = 0,
        .col_num = 4,
        .rows = 9,
    }, .{ .row_num = 0 });

    canvas.blitFrom(error_box, .{ .row_num = 10, .col_num = 4 }, .{ .row_num = @intCast(isize, focus_row) });

    try zbox.push(canvas);
}

pub fn display_loop(context: void) !void {
    var alloc = page_allocator;

    // initialize the zbox with stdin/out
    try zbox.init(alloc);
    defer zbox.deinit();

    // die on ctrl+C
    try zbox.handleSignalInput();
    // try zbox.ignoreSignalInput();
    //setup our drawing buffer
    var size = try zbox.size();

    canvas = try zbox.Buffer.init(alloc, size.height, size.width);
    defer canvas.deinit();

    box = try zbox.Buffer.init(alloc, 9999, 50);
    defer box.deinit();

    error_box = try zbox.Buffer.init(alloc, 9999, 50);
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
            .up => {
                if (focus_row > 0)
                    focus_row -= 1;
                node.enqueue(node.Job{ .redraw = 0 }) catch unreachable;
            },
            .down => {
                focus_row += 1;
                node.enqueue(node.Job{ .redraw = 0 }) catch unreachable;
            },
            .left => {
                prev_mode();
                node.enqueue(node.Job{ .redraw = 0 }) catch unreachable;
            },
            .right => {
                next_mode();
                node.enqueue(node.Job{ .redraw = 0 }) catch unreachable;
            },
            .escape => {
                node.enqueue(node.Job{ .shutdown = 0 }) catch unreachable;
            },
        }
    }
}

test "static anal" {
    std.meta.refAllDecls(@This());
}
