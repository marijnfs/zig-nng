const std = @import("std");
const logger = @import("logger.zig");

const defines = @import("defines.zig");
const Guid = defines.Guid;
const ID = defines.ID;
const Address = defines.Address;

const node = @import("node.zig");
const utils = @import("utils.zig");

pub const Response = union(enum) {
    ping_id: struct {
        conn_guid: Guid,
        id: ID,
        inbound_sockaddr: std.os.sockaddr,
        port: u16,
        pub fn format(r: @This(), comptime fmt: []const u8, options: std.fmt.FormatOptions, out: anytype) !void {
            try out.print("{any} {s} {any} {any}", .{ r.conn_guid, std.fmt.fmtSliceHexLower(r.id[0..]), r.inbound_sockaddr, r.port });
        }
    },
    broadcast_confirm: usize,
    nearest_peer: struct {
        search_id: ID,
        nearest_id: ID,
        address: ?Address,
        pub fn format(r: @This(), comptime fmt: []const u8, options: std.fmt.FormatOptions, out: anytype) !void {
            try out.print("{s} {s} {s}", .{ std.fmt.fmtSliceHexLower(r.search_id[0..8]), std.fmt.fmtSliceHexLower(r.nearest_id[0..8]), r.address });
        }
    },
    already_seen: u8,
};

pub fn handle_response(guid: u64, response: Response) !void {
    logger.log_fmt("Response: {}\n", .{response});

    // check guid for chainable messages
    switch (response) {
        .ping_id, .nearest_peer => {
            var for_me: bool = node.self_guids.get(guid) != null;
            if (for_me) {
                logger.log_fmt("message for me! {} {}\n", .{ guid, response });
            } else {
                logger.log_fmt("Passing message on, guid not for me: {} {}\n", .{ guid, response });
                logger.log_fmt("{}\n", .{node.self_guids.count()});
                try node.enqueue(node.Job{ .send_response = .{ .guid = guid, .enveloped = response } });
                return;
            }
        },
        else => {},
    }

    switch (response) {
        .ping_id => {
            // We got a ping response.
            // The ping response is supposed to give us some information:
            // 1. Our perceived IP address
            // 2. The ID of the node we connected to
            logger.log_fmt("got resp ping id {}\n", .{response.ping_id});
            const conn_guid = response.ping_id.conn_guid;

            // Grab the perceived nng_sockaddr and retreive our supposed IP addr
            var my_addr = response.ping_id.inbound_sockaddr;

            // We hard set the port, since this is our inbound port, which is not known the the connecting node
            my_addr.s_in.sa_port = @intCast(u16, node.my_port);
            const add_port = true;
            const my_addr_string = try utils.sockaddr_to_string(response.ping_id.inbound_sockaddr, add_port);

            // Set our address
            node.my_address = my_addr_string;
            logger.log_fmt("Setting perceived address to {s}\n", .{node.my_address});
            try node.self_addresses.put(my_addr_string, true);

            // Set the ID of the connection point to the reveived ID
            var conn = try node.connection_by_guid(conn_guid);
            conn.id = response.ping_id.id;
        },
        .broadcast_confirm => {
            logger.log_fmt("got broadcast confirm\n", .{});
        },
        .nearest_peer => |nearest_peer| {
            logger.log_fmt("Got nearest peer info: {}", .{response});

            if (nearest_peer.address) |address| {
                const search_id = nearest_peer.search_id;
                const reported_id = nearest_peer.nearest_id;

                // first verify we actually asked this search id
                if (node.finger_table.get(search_id)) |_| {} else {
                    logger.log_fmt("got peer info with unrequested search id: {any}\n", .{search_id});
                    return;
                }

                try node.finger_table.put(search_id, .{ .id = reported_id, .address = address });
            }
        },
        .already_seen => {
            logger.log("peer responded with already_seen");
        },
    }
}
