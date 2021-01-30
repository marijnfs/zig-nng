const std = @import("std");
const warn = std.debug.warn;

const c = @import("c.zig").c;
const nng_ret = @import("c.zig").nng_ret;

const defines = @import("defines.zig");
const Guid = defines.Guid;
const ID = defines.ID;
const node = @import("node.zig");
const utils = @import("utils.zig");

pub const Response = union(enum) {
    ping_id: struct { id: ID, sockaddr: c.nng_sockaddr },
    peer_before: ID,
    broadcast_confirm: void,
};

pub fn handle_response(guid: u64, response: Response) !void {
    var for_me: bool = guid == node.self_guid;

    if (for_me) {
        warn("message for me! {} {}", .{ guid, response });
    }

    switch (response) {
        .ping_id => {
            warn("got resp ping id {}\n", .{response.ping_id});
            const port = false;
            const my_addr_string = try utils.sockaddr_to_string(response.ping_id.sockaddr, port);
            try node.self_addresses.put(my_addr_string, true);
            var conn = try node.connection_by_guid(guid);
            conn.id = response.ping_id.id;
        },
        .peer_before => {},
        .broadcast_confirm => {
            warn("got broadcast confirm\n", .{});
        },
    }
}
