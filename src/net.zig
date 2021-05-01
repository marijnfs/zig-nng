const std = @import("std");
const network = @import("zig-network");
const allocator = @import("defines.zig").allocator;

pub fn init() !void {
    try network.init();
}

const Connection = struct {
    socket: network.Socket = undefined,
    done: bool = false,
    // handle_frame: @Frame(Client.handle),

    pub fn create_ipv4(self: *Connection) !void {
        self.socket = try network.Socket.create(.ipv4, .tcp);
    }

    pub fn close(self: *Connection) void {
        self.socket.close();
    }

    pub fn bind(self: *Connection, endpoint: network.EndPoint) !void {
        try server.bind(endpoint);
    }

    pub fn bindToPort(self: *Connection, port: u16) !void {
        try server.bindToPort(port);
    }

    pub fn listen(self: *Connection) !void {
        try server.listen();
    }

    pub fn accept(self: *Connection) !void {
        const conn = try server.accept();
    }

    pub fn recv(self: *Connection, allocator: *std.mem.Allocator) ![]u8 {
        var buf: [1024]u8 = undefined;
        const amt = try self.socket.receive(&buf);

        const msg = std.mem.dupe(allocator, u8, buf[0..amt]);
        std.debug.print("Client wrote: {s}", .{msg});
        return msg;
    }

    pub fn getLocalEndPoint(self: *Connection) !network.EndPoint {
        return try self.socket.getLocalEndPoint();
    }
};
