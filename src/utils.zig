const std = @import("std");
const warn = std.debug.warn;

const c = @import("c.zig").c;
const nng_ret = @import("c.zig").nng_ret;

const defines = @import("defines.zig");
const Guid = defines.Guid;
const ID = defines.ID;
const allocator = defines.allocator;

pub fn calculate_hash(data: []const u8) ID {
    var result: ID = undefined;
    std.crypto.hash.Blake3.hash(data, result[0..], .{});
    return result;
}

pub fn sockaddr_to_string(sockaddr: c.nng_sockaddr, with_port: bool) ![:0]u8 {
    const fam = sockaddr.s_family;

    if (fam == c.NNG_AF_INET) {
        const ipv4 = sockaddr.s_in;

        var addr = ipv4.sa_addr;
        const addr_ptr = @ptrCast([*]u8, &addr);
        if (!with_port) {
            return try std.fmt.allocPrintZ(allocator, "tcp://{}.{}.{}.{}", .{ addr_ptr[0], addr_ptr[1], addr_ptr[2], addr_ptr[3] });
        } else {
            return try std.fmt.allocPrintZ(allocator, "{}.{}.{}.{}:{}", .{ addr_ptr[0], addr_ptr[1], addr_ptr[2], addr_ptr[3], ipv4.sa_port });
        }
    }
    if (fam == c.NNG_AF_INET6) {
        const ipv6 = sockaddr.s_in6;
        var addr = ipv6.sa_addr;
        const addr_ptr = @ptrCast([*]u8, &addr);

        const buffer = if (with_port)
            try std.fmt.allocPrintZ(allocator, "tcp://{x}{x}:{x}{x}:{x}{x}:{x}{x}:{x}{x}:{x}{x}:{x}{x}:{x}{x}:/{}", .{
                addr_ptr[0],  addr_ptr[1],  addr_ptr[2],  addr_ptr[3],  addr_ptr[4],
                addr_ptr[5],  addr_ptr[6],  addr_ptr[7],  addr_ptr[8],  addr_ptr[9],
                addr_ptr[10], addr_ptr[11], addr_ptr[12], addr_ptr[13], addr_ptr[14],
                addr_ptr[15], ipv6.sa_port,
            })
        else
            try std.fmt.allocPrintZ(allocator, "tcp://{x}{x}:{x}{x}:{x}{x}:{x}{x}:{x}{x}:{x}{x}:{x}{x}:{x}{x}", .{
                addr_ptr[0],  addr_ptr[1],  addr_ptr[2],  addr_ptr[3],  addr_ptr[4],
                addr_ptr[5],  addr_ptr[6],  addr_ptr[7],  addr_ptr[8],  addr_ptr[9],
                addr_ptr[10], addr_ptr[11], addr_ptr[12], addr_ptr[13], addr_ptr[14],
                addr_ptr[15],
            });
        return buffer;
    }

    return error.SockaddrPrintUnsupported;
}
