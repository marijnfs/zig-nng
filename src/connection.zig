const std = @import("std");

const Connection = @This();

const defines = @import("defines.zig");
const c = @import("c.zig").c;
const nng_ret = @import("c.zig").nng_ret;

const Guid = defines.Guid;
const ID = defines.ID;
const Address = defines.Address;
const allocator = defines.allocator;
const logger = @import("logger.zig");
const warn = @import("std").debug.warn;

const node = @import("node.zig");
pub const State = enum {
    Init,
    Connected,
    Disconnected,
};

guid: Guid,
address: Address,

id: ID = undefined,
n_workers: usize = 0,
socket: c.nng_socket = undefined,

state: State = .Init,

pub fn id_known(self: *Connection) bool {
    return !node.is_zero(self.id);
}

pub fn alloc() !*Connection {
    return try allocator.create(Connection);
}

pub fn free(self: *Connection) void {
    allocator.destroy(self);
}

pub fn init(self: *Connection, address: Address) void {
    self.* = Connection{
        .address = address,
        .guid = defines.get_guid(),
    };

    std.mem.set(u8, self.id[0..], 0);
}

pub fn req_open(
    self: *Connection,
) !void {
    logger.log_fmt("req open {s}\n", .{self.address});
    var r: c_int = undefined;
    try nng_ret(c.nng_req0_open(&self.socket));
}

pub fn rep_open(self: *Connection) !void {
    logger.log_fmt("rep open {s}\n", .{self.address});
    var r: c_int = undefined;
    try nng_ret(c.nng_rep0_open(&self.socket));
}

pub fn dial(self: *Connection) !void {
    logger.log_fmt("dialing {s}\n", .{self.address});
    try nng_ret(c.nng_dial(self.socket, self.address, 0, 0));
}

pub fn listen(self: *Connection) !void {
    try nng_ret(c.nng_listen(self.socket, self.address, 0, 0));
}

pub fn format(con: @This(), comptime fmt: []const u8, options: std.fmt.FormatOptions, out: anytype) !void {
    try out.print("giud:{} id:{s} addr:{s}", .{ con.guid, std.fmt.fmtSliceHexLower(con.id[0..8]), con.address });
}
