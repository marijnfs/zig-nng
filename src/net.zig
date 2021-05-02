const std = @import("std");
const network = @import("zig-network");
const allocator = @import("defines.zig").allocator;

var server = Connection{};

pub fn init() !void {
    try network.init();
    var frame = async server_loop();
}

pub fn server_loop() !void {
    try server.create_ipv4();
    try server.bindToPort(2000);
    try server.listen();

    while (true) {
        var socket = try server.accept();
        var connection = Connection{ .socket = socket };
    }
}

const Connection = struct {
    socket: network.Socket = undefined,
    finished: bool = false,
    // handle_frame: @Frame(Client.handle),

    pub fn create_ipv4(self: *Connection) !void {
        self.socket = try network.Socket.create(.ipv4, .tcp);
    }

    pub fn close(self: *Connection) void {
        self.socket.close();
    }

    pub fn bind(self: *Connection, endpoint: network.EndPoint) !void {
        try self.socket.bind(endpoint);
    }

    pub fn connect(self: *Connection, endpoint: network.EndPoint) !void {
        try self.socket.connect(endpoint);
    }

    pub fn bindToPort(self: *Connection, port: u16) !void {
        try self.socket.bindToPort(port);
    }

    pub fn listen(self: *Connection) !void {
        try self.socket.listen();
    }

    pub fn accept(self: *Connection) !network.Socket {
        return try self.socket.accept();
    }

    pub fn recv(self: *Connection, allocator: *std.mem.Allocator) ![]u8 {
        var buf: [1024]u8 = undefined;
        const amt = try self.socket.receive(&buf);

        const msg = std.mem.dupe(allocator, u8, buf[0..amt]);
        std.debug.print("Client wrote: {s}", .{msg});
        return msg;
    }

    pub fn send(self: *Connection, buf: []u8) !void {
        _ = try self.socket.send(&buf);
    }

    pub fn getLocalEndPoint(self: *Connection) !network.EndPoint {
        return try self.socket.getLocalEndPoint();
    }

    pub fn connectionLoop(self: *Connection, endpoint: network.Endpoint) !void {}
};
