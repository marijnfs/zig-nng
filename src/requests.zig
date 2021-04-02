const std = @import("std");
const warn = std.debug.warn;
const logger = @import("logger.zig");

const c = @import("c.zig").c;
const nng_ret = @import("c.zig").nng_ret;
const utils = @import("utils.zig");

const defines = @import("defines.zig");
const Guid = defines.Guid;
const ID = defines.ID;

const node = @import("node.zig");
const Job = node.Job;

pub const Request = union(enum) {
    ping_id: struct { conn_guid: Guid, port: u16 },
    nearest_peer: ID,
    broadcast: node.Message,
};

pub fn handle_request(guid: Guid, request: Request, msg: *c.nng_msg) !void {
    logger.log_fmt("req{}\n", .{request});
    switch (request) {
        .ping_id => |ping_id| {
            const conn_guid = ping_id.conn_guid; //Guid that requesting node uses to assign Connection
            logger.log_fmt("requesting pingid, guid and conn guid: {x} {x}\n", .{ guid, conn_guid });
            const pipe = c.nng_msg_get_pipe(msg);
            var sockaddr: c.nng_sockaddr = undefined;
            try nng_ret(c.nng_pipe_get_addr(pipe, c.NNG_OPT_REMADDR, &sockaddr));

            // connecting addr, add it to known
            sockaddr.s_in.sa_port = ping_id.port;
            const with_port = true;
            const address_str = try utils.sockaddr_to_string(sockaddr, with_port);
            try node.known_addresses.append(address_str);

            logger.log_fmt("ping from {s}\n", .{address_str});
            try node.enqueue(Job{ .send_response = .{ .guid = guid, .enveloped = .{ .ping_id = .{ .conn_guid = conn_guid, .id = node.my_id, .inbound_sockaddr = sockaddr, .port = node.my_port } } } });
        },
        .nearest_peer => {
            const search_id = request.nearest_peer;
            var nearest_distance = node.xor(node.my_id, search_id);
            var nearest_id = node.my_id;
            if (node.is_zero(node.my_id)) {
                logger.log_fmt("My address is not known yet\n", .{});
                try node.enqueue(Job{ .send_response = .{ .guid = guid, .enveloped = .{ .nearest_peer = .{ .search_id = search_id, .nearest_id = nearest_id, .address = null } } } });
                return;
            }

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
                    logger.log_fmt("My address is not known yet\n", .{});
                    try node.enqueue(Job{ .send_response = .{ .guid = guid, .enveloped = .{ .nearest_peer = .{ .search_id = search_id, .nearest_id = nearest_id, .address = null } } } });
                } else {
                    try node.enqueue(Job{ .send_response = .{ .guid = guid, .enveloped = .{ .nearest_peer = .{ .search_id = search_id, .nearest_id = nearest_id, .address = node.my_address.? } } } });
                }
            } else {
                const nearest_conn = try node.connection_by_nearest_id(search_id);
                try node.enqueue(Job{ .send_request = .{ .conn_guid = nearest_conn.guid, .guid = guid, .enveloped = request } });
            }
        },
        .broadcast => {
            const message = request.broadcast;
            try node.enqueue(Job{ .send_response = .{ .guid = guid, .enveloped = .{ .broadcast_confirm = 0 } } });

            if (node.guid_seen.get(guid)) |seen| {
                logger.log_fmt("already saw message, not broadcasting\n", .{});
                return;
            } else {
                try node.guid_seen.put(guid, true);
            }
            try node.enqueue(Job{ .print_msg = .{ .content = message.content } });
            try node.enqueue(Job{ .broadcast_msg = .{ .guid = guid, .enveloped = message } });

            logger.log_fmt("responding to guid {}\n", .{guid});
        },
    }
}

test "serialise" {
    const serialise = @import("serialise.zig");

    const req = Request{ .ping_id = .{ .conn_guid = 10 } };

    var msg: ?*c.nng_msg = undefined;
    try nng_ret(c.nng_msg_alloc(&msg, 0));

    try serialise.serialise_msg(req, msg.?);
    const req_deserialized = try serialise.deserialise_msg(Request, msg.?);

    logger.log_fmt("{} {}\n", .{ req, req_deserialized });
}
