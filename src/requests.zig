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
    ping_id: ID,
    peer_before: ID,
};

pub fn handle_request(guid: Guid, request: Request, msg: *c.nng_msg) !void {
    warn("req{}\n", .{request});
    switch (request) {
        .ping_id => {
            warn("requesting pingid\n", .{});
            const pipe = c.nng_msg_get_pipe(msg);
            var sockaddr: c.nng_sockaddr = undefined;
            try nng_ret(c.nng_pipe_get_addr(pipe, c.NNG_OPT_REMADDR, &sockaddr));
            const with_port = false;

            // connecting addr, add it to known
            const address_str = try utils.sockaddr_to_string(sockaddr, with_port);
            try node.known_addresses.append(address_str);
            warn("ping from {s}\n", .{address_str});
            try node.enqueue(Job{ .send_response = .{ .guid = guid, .response = .{ .ping_id = .{ .id = node.my_id, .sockaddr = sockaddr } } } });
        },
        .peer_before => {},
    }
}
