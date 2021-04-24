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

    if (node.guid_seen.get(guid)) |_| {
        // We already got this request, drop it
        logger.log_fmt("Already seen, dropping request with guid: {}\n", .{guid});
        return;
    }
    try node.guid_seen.put(guid, true);

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
        .nearest_peer => |search_id| {
            //todo: pass on message even if you don't know yours
            //make sure to not consider self if equal to search id
            //make sure not to infinite loop message
            var nearest_distance = node.xor(node.my_id, search_id);
            var nearest_id = node.my_id;
            if (node.is_zero(node.my_id)) {
                logger.log_fmt("My address is not known yet\n", .{});
                try node.enqueue(Job{ .send_response = .{ .guid = guid, .enveloped = .{ .nearest_peer = .{ .search_id = search_id, .nearest_id = nearest_id, .address = null } } } });
                return;
            }

            var im_closest = true;
            for (node.connections.items) |connection| {
                if (connection.id_known() and
                    !std.mem.eql(u8, connection.id[0..], search_id[0..])) //we want nearest but not equal, this is important for finding your nearest peer
                {
                    const dist = node.xor(connection.id, search_id);
                    if (node.less(dist, nearest_distance)) {
                        nearest_distance = dist;
                        nearest_id = connection.id;
                        im_closest = false;
                    }
                }
            }

            if (im_closest) {
                try node.enqueue(Job{ .send_response = .{ .guid = guid, .enveloped = .{ .nearest_peer = .{ .search_id = search_id, .nearest_id = nearest_id, .address = node.my_address } } } });
            } else {
                // pass on request
                const nearest_conn = try node.connection_by_nearest_id(search_id);
                try node.enqueue(Job{ .send_request = .{ .conn_guid = nearest_conn.guid, .guid = guid, .enveloped = request } });
            }
        },
        .broadcast => |message| {
            try node.enqueue(Job{ .send_response = .{ .guid = guid, .enveloped = .{ .broadcast_confirm = 0 } } });
            try node.enqueue(Job{ .broadcast_msg = .{ .guid = guid, .enveloped = message } });
            try node.enqueue(Job{ .add_message_to_model = .{ .content = message.content } });
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
