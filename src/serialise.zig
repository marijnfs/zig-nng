const std = @import("std");
const warn = std.debug.warn;
const mem = std.mem;
const c = @import("c.zig").c;
const nng_ret = @import("c.zig").nng_ret;
const allocator = @import("defines.zig").allocator;

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
        .Void => {},
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
            if (comptime std.meta.trait.isSlice(T)) {
                var len: u64 = 0;
                try nng_ret(c.nng_msg_trim_u64(msg, &len));
                const data_slice = msg_to_slice(msg);
                const C = comptime std.meta.Child(T);

                if (len * @sizeOf(C) > data_slice.len)
                    return error.FailedToDeserialise;

                if (comptime std.meta.sentinel(T) == null) {
                    t = try allocator.alloc(C, len);
                    std.mem.copy(C, t, data_slice);
                } else {
                    t = try allocator.allocSentinel(C, len, 0);
                    std.mem.copy(C, t, data_slice);
                }
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
                        warn("deserialise type: {}\n", .{FieldType});
                        t = @unionInit(T, name, try deserialise_msg(FieldType, msg));
                    }
                }
            } else { // c struct or general struct
                const bytes_mem = mem.asBytes(&t);
                const msg_slice = msg_to_slice(msg);
                if (bytes_mem.len > msg_slice.len)
                    return error.FailedToDeserialise;
                mem.copy(u8, bytes_mem, msg_slice[0..bytes_mem.len]);
                try nng_ret(c.nng_msg_trim(msg, bytes_mem.len));
            }
        },
        .Enum => {
            t = blk: {
                var int_operand: u32 = 0;
                nng_ret(c.nng_msg_trim_u32(msg, &int_operand)) catch {
                    warn("Failed to read operand\n", .{});
                    return error.DeserialisationFail;
                };
                break :blk @intToEnum(T, @intCast(std.meta.TagType(T), int_operand));
            };
        },
        .Int => {
            const bytes_mem = mem.asBytes(&t);
            const msg_slice = msg_to_slice(msg);
            if (bytes_mem.len > msg_slice.len)
                return error.FailedToDeserialise;
            mem.copy(u8, bytes_mem, msg_slice[0..bytes_mem.len]);
            try nng_ret(c.nng_msg_trim(msg, bytes_mem.len));
        },
        .Optional => {
            const C = comptime std.meta.Child(T);
            const opt = try deserialise_msg(u8, msg);
            if (opt > 0) {
                t = try deserialise_msg(C, msg);
            } else {
                t = null;
            }
        },
        else => @compileError("Cannot deserialise " ++ @tagName(@typeInfo(T)) ++ " types (unimplemented)."),
    }
    return t;
}

pub fn serialise_msg(t: anytype, msg: *c.nng_msg) !void {
    const T = comptime @TypeOf(t);

    const info = @typeInfo(T);
    switch (info) {
        .Void => {},
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
            if (comptime std.meta.trait.isSlice(T)) {
                const C = std.meta.Child(T);
                try nng_ret(c.nng_msg_append_u64(msg, @intCast(u64, t.len)));
                try nng_ret(c.nng_msg_append(msg, @ptrCast(*c_void, t), @sizeOf(C) * t.len));
            } else {
                @compileError("Expected to serialise slice");
            }
        },
        .Union => {
            if (info.Union.tag_type) |TagType| {
                const active_tag = std.meta.activeTag(t);
                try serialise_msg(@as(std.meta.TagType(T), active_tag), msg);

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
        .Int => {
            const bytes_mem = mem.asBytes(&t);
            var tmp = t;
            try nng_ret(c.nng_msg_append(msg, @ptrCast(*c_void, &tmp), @sizeOf(T)));
        },
        .Optional => {
            if (t == null) {
                const opt: u8 = 0;
                try serialise_msg(opt, msg);
            } else {
                const opt: u8 = 1;
                try serialise_msg(opt, msg);
                try serialise_msg(t.?, msg);
            }
        },
        else => @compileError("Cannot serialise " ++ @tagName(@typeInfo(T)) ++ " types (unimplemented)."),
    }
}
