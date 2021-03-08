const std = @import("std");
const warn = std.debug.warn;
const mem = std.mem;

pub fn serialise_msg(t: anytype) !void {
    const T = comptime @TypeOf(t);

    warn("serialise_msg({any})\n", .{t});
    const info = @typeInfo(T);
    switch (info) {
        .Void => {},
        .Struct => {
            inline for (info.Struct.fields) |*field_info| {
                const name = field_info.name;
                const FieldType = field_info.field_type;
                warn("serialising struct field {s} {any}\n", .{ name, @field(t, name) });
                try serialise_msg(@field(t, name));
            }
        },
        .Array => {},
        .Pointer => {
            if (comptime std.meta.trait.isSlice(T)) {
                const C = std.meta.Child(T);
            } else {
                @compileError("Expected to serialise slice");
            }
        },
        .Union => {
            if (info.Union.tag_type) |TagType| {
                const active_tag = std.meta.activeTag(t);
                warn("serialising tag {}\n", .{@as(std.meta.TagType(T), active_tag)});

                try serialise_msg(@as(std.meta.TagType(T), active_tag));
                warn("serialising Union {}\n", .{active_tag});

                inline for (info.Union.fields) |field_info| {
                    if (@field(TagType, field_info.name) == active_tag) {
                        const name = field_info.name;
                        const FieldType = field_info.field_type;
                        try serialise_msg(@field(t, name));
                    }
                }

                warn("done serialising Union \n", .{});
            } else {}
        },
        .Enum => {},
        .Int => {
            const bytes_mem = mem.asBytes(&t);
            var tmp = t;
        },
        .Optional => {
            if (t == null) {
                const opt: u8 = 0;
                try serialise_msg(opt);
            } else {
                const opt: u8 = 1;
                try serialise_msg(opt);
                try serialise_msg(t.?);
            }
        },
        else => @compileError("Cannot serialise " ++ @tagName(@typeInfo(T)) ++ " types (unimplemented)."),
    }
}

pub const Bla = union(enum) {
    somestruct3: struct {
        an_id: i64,
        address: ?[:0]u8,
    },
    somestruct1: struct { an_id: i64 },
    somevoid: void,
    somestruct2: struct { an_id: [32]u8, an_id2: [32]u8 },
};

test "something" {
    var bla = Bla{ .somestruct1 = .{ .an_id = 10 } };
    try serialise_msg(bla);

    var id: [32]u8 = undefined;
    var id2: [32]u8 = undefined;
    var bla2 = Bla{ .somestruct2 = .{ .an_id = id, .an_id2 = id2 } };
    try serialise_msg(bla2);

    var bla3 = Bla{ .somestruct3 = .{ .an_id = 2, .address = null } };
    try serialise_msg(bla3);
}
