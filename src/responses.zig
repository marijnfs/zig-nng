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
    ping_id: struct { conn_guid: Guid, id: ID, sockaddr: c.nng_sockaddr },
    broadcast_confirm: void,
    nearest_peer: struct { search_id: ID, nearest_id: ID, address: ?[:0]u8 },
    nearest_peer2: struct { conn_guid: Guid },
};

pub fn handle_response(guid: u64, response: Response) !void {
    warn("Response: {}\n", .{response});
    var for_me: bool = node.self_guids.get(guid) != null;

    if (for_me) {
        warn("message for me! {} {}", .{ guid, response });
    }

    if (!for_me) {
        warn("Passing message on, guid not for me: {} {}\n", .{ guid, response });
        warn("{}\n", .{node.self_guids.count()});
        try node.enqueue(node.Job{ .send_response = .{ .guid = guid, .enveloped = response } });
        return;
    }

    switch (response) {
        .ping_id => {
            warn("got resp ping id {}\n", .{response.ping_id});
            const conn_guid = response.ping_id.conn_guid;

            const port = false;
            const my_addr_string = try utils.sockaddr_to_string(response.ping_id.sockaddr, port);
            node.my_address = my_addr_string;
            try node.self_addresses.put(my_addr_string, true);

            var conn = try node.connection_by_guid(conn_guid);
            conn.id = response.ping_id.id;
            warn("Set to id: {x}\n", .{std.fmt.fmtSliceHexLower(conn.id[0..])});
        },
        .broadcast_confirm => {
            warn("got broadcast confirm\n", .{});
        },
        .nearest_peer => {
            warn("Got nearest peer info: {}", .{response});
        },
        .nearest_peer2 => {},
    }
}
