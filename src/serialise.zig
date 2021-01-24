const std = @import("std");
const warn = std.debug.warn;
const mem = std.mem;
const c = @import("c.zig").c;
const nng_ret = @import("c.zig").nng_ret;

fn msg_to_ptr(comptime T: type, msg: *c.nng_msg) !*T {
    const len = c.nng_msg_len(msg);
    if (len < @sizeOf(T))
        return error.ReadBeyondLimit;
    return @ptrCast(*T, c.nng_msg_body(msg));
}

fn msg_to_slice(msg: *c.nng_msg) []u8 {
    const len = c.nng_msg_len(msg);
    const body = @ptrCast([*]u8, c.nng_msg_body(msg));
    return body[0..len];
}

pub fn deserialise_msg(comptime T: type, msg: *c.nng_msg) !T {
    var t: T = undefined;
    const info = @typeInfo(T);

    switch (info) {
        .Struct => {
            inline for (info.Struct.fields) |*field_info| {
                const name = field_info.name;
                const FieldType = field_info.field_type;

                @field(&t, name) = try deserialise_msg(FieldType, msg);
            }
        },
        .Array => {
            const len = info.Array.len;
            const byteSize = @sizeOf(std.meta.Child(T)) * len;

            if (c.nng_msg_len(msg) < byteSize) {
                return error.MsgSmallerThanArray;
            }

            const body_slice = msg_to_slice(msg);

            const bodyPtr = try msg_to_ptr(T, msg);
            mem.copy(u8, &t, bodyPtr);
            try nng_ret(c.nng_msg_trim(
                msg,
                @sizeOf(T),
            ));
        },
        .Pointer => {
            if (comptime std.meta.trait.isSlice(info)) {
                // var len: u64 = 0;
                // try nng_ret(c.nng_msg_trim_u64(msg, @intCast(u64, &len)));
                // try nng_ret(c.nng_msg_append(msg, @ptrCast(*c_void, &t), @sizeOf(meta.Child(T)) * len));
            } else {
                @compileError("Expected to serialise slice");
            }
        },
        .Union => {
            if (comptime info.Union.tag_type) |TagType| {
                const active_tag = try deserialise_msg(TagType, msg);
                inline for (info.Union.fields) |field_info| {
                    if (@field(TagType, field_info.name) == active_tag) {
                        const name = field_info.name;
                        const FieldType = field_info.field_type;
                        warn("deserialize type: {}\n", .{FieldType});
                        t = @unionInit(T, name, try deserialise_msg(FieldType, msg));
                    }
                }
            } else { // c struct or general struct
                const bytes_mem = mem.asBytes(&t);
                const msg_slice = msg_to_slice(msg);
                if (bytes_mem.len > msg_slice.len)
                    return error.FailedToDeserialize;
                mem.copy(u8, mem.asBytes(&t), msg_to_slice(msg));
                try nng_ret(c.nng_msg_trim(msg, @sizeOf(T)));
            }
        },
        .Enum => {
            t = blk: {
                var int_operand: u32 = 0;
                nng_ret(c.nng_msg_trim_u32(msg, &int_operand)) catch {
                    warn("Failed to read operand\n", .{});
                    return error.DeserialisationFail;
                };
                break :blk @intToEnum(T, @intCast(@TagType(T), int_operand));
            };
        },
        else => @compileError("Cannot deserialize " ++ @tagName(@typeInfo(T)) ++ " types (unimplemented)."),
    }
    return t;
}

pub fn serialise_msg(t: anytype, msg: *c.nng_msg) !void {
    const T = comptime @TypeOf(t);

    const info = @typeInfo(T);
    switch (info) {
        .Struct => {
            inline for (info.Struct.fields) |*field_info| {
                const name = field_info.name;
                const FieldType = field_info.field_type;
                try serialise_msg(@field(t, name), msg);
            }
        },
        .Array => {
            const len = info.Array.len;
            var tmp = t;
            try nng_ret(c.nng_msg_append(msg, @ptrCast(*c_void, &tmp), @sizeOf(std.meta.Child(T)) * len));
        },
        .Pointer => {
            if (comptime std.meta.trait.isSlice(info)) {
                try nng_ret(c.nng_msg_append_u64(msg, @intCast(u64, info.len)));
                try nng_ret(c.nng_msg_append(msg, @ptrCast(*c_void, &t), @sizeOf(std.meta.Child(T)) * t.len));
            } else {
                @compileError("Expected to serialise slice");
            }
        },
        .Union => {
            if (info.Union.tag_type) |TagType| {
                const active_tag = std.meta.activeTag(t);
                try serialise_msg(@as(@TagType(T), active_tag), msg);

                inline for (info.Union.fields) |field_info| {
                    if (@field(TagType, field_info.name) == active_tag) {
                        const name = field_info.name;
                        const FieldType = field_info.field_type;
                        try serialise_msg(@field(t, name), msg);
                    }
                }
            } else {
                const bytes_mem = mem.asBytes(&t);
                var tmp = t;
                try nng_ret(c.nng_msg_append(msg, @ptrCast(*c_void, &tmp), @sizeOf(T)));
            }
        },
        .Enum => {
            try nng_ret(c.nng_msg_append_u32(msg, @intCast(u32, @enumToInt(t))));
        },
        else => @compileError("Cannot serialize " ++ @tagName(@typeInfo(T)) ++ " types (unimplemented)."),
    }
}
