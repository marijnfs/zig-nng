const std = @import("std");
const warn = std.debug.warn;

const c = @import("c.zig").c;
const nng_ret = @import("c.zig").nng_ret;
const utils = @import("utils.zig");

const defines = @import("defines.zig");
const Guid = defines.Guid;
const ID = defines.ID;

const node = @import("node.zig");
const Job = node.Job;

pub const Request = union(enum) {
    ping_id: struct { conn_guid: Guid },
    nearest_peer: ID,
    broadcast: node.Message,
};

pub fn handle_request(guid: Guid, request: Request, msg: *c.nng_msg) !void {
    warn("req{}\n", .{request});
    switch (request) {
        .ping_id => {
            const conn_guid = request.ping_id.conn_guid; //Guid that requesting node uses to assign Connection
            warn("requesting pingid\n", .{});
            const pipe = c.nng_msg_get_pipe(msg);
            var sockaddr: c.nng_sockaddr = undefined;
            try nng_ret(c.nng_pipe_get_addr(pipe, c.NNG_OPT_REMADDR, &sockaddr));
            const with_port = false;

            // connecting addr, add it to known
            const address_str = try utils.sockaddr_to_string(sockaddr, with_port);
            try node.known_addresses.append(address_str);
            warn("ping from {s}\n", .{address_str});
            try node.enqueue(Job{ .send_response = .{ .guid = guid, .enveloped = .{ .ping_id = .{ .conn_guid = conn_guid, .id = node.my_id, .sockaddr = sockaddr } } } });
        },
        .nearest_peer => {
            const search_id = request.nearest_peer;
            var nearest_distance = node.xor(node.my_id, search_id);
            var nearest_id = node.my_id;
            var im_closest = true;
            for (node.connections.items) |connection| {
                if (connection.id_known()) {
                    const dist = node.xor(connection.id, search_id);
                    if (node.less(dist, nearest_distance)) {
                        nearest_distance = dist;
                        nearest_id = connection.id;
                        im_closest = false;
                    }
                }
            }

            if (im_closest) {
                if (node.my_address == null) {
                    warn("My address is not known yet\n", .{});
                    return;
                }
                try node.enqueue(Job{ .send_response = .{ .guid = guid, .enveloped = .{ .nearest_peer = .{ .search_id = search_id, .nearest_id = nearest_id, .address = node.my_address.? } } } });
            } else {
                const nearest_conn = try node.connection_by_nearest_id(search_id);
                try node.enqueue(Job{ .send_request = .{ .conn_guid = nearest_conn.guid, .guid = guid, .enveloped = request } });
            }
        },
        .broadcast => {
            const message = request.broadcast;
            try node.enqueue(Job{ .send_response = .{ .guid = guid, .enveloped = .{ .broadcast_confirm = {} } } });

            if (node.guid_seen.get(guid)) |seen| {
                warn("already saw message, not broadcasting\n", .{});
                return;
            } else {
                try node.guid_seen.put(guid, true);
            }
            try node.enqueue(Job{ .print_msg = .{ .content = message.content } });
            try node.enqueue(Job{ .broadcast_msg = .{ .guid = guid, .enveloped = message } });

            warn("responding to guid {}\n", .{guid});
        },
    }
}
