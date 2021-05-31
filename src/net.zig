const std = @import("std");
const network = @import("zig-network");
const allocator = @import("defines.zig").allocator;
const defines = @import("defines.zig");

const Guid = defines.Guid;
const ID = defines.ID;
const Address = defines.Address;

var server: Connection = undefined;

pub fn init() !void {
    try network.init();
}

pub fn server_loop(port: u16) !void {
    server = try Connection.create_ipv4();
    try server.bindToPort(port);
    try server.listen();

    while (true) {
        var socket = try server.accept();
        var connection = Connection{ .socket = socket };
        std.debug.warn("loop\n", .{});
    }
}

pub fn get_endpoint_list(name: []u8, port: u16) ![]network.EndPoint {
    var endpoints = try network.getEndpointList(allocator, name, port);
    defer endpoints.deinit();

    return std.mem.dupe(allocator, network.EndPoint, endpoints.endpoints);
}

pub const Connection = struct {
    socket: network.Socket = undefined,
    guid: Guid,
    address: Address,

    id: ID = undefined,

    pub const State = enum {
        Init,
        Connected,
        Disconnected,
    };

    // handle_frame: @Frame(Client.handle),

    pub fn create(endpoint: network.EndPoint) !Connection {
        var connection: Connection = Connection{};
        switch (endpoint.toSocketAddress()) {
            .ipv4 => |sockaddr| connection.socket = try network.Socket.create(.ipv4, .tcp),
            .ipv6 => |sockaddr| connection.socket = try network.Socket.create(.ipv6, .tcp),
        }
        return connection;
    }

    pub fn create_ipv4() !Connection {
        var con = Connection{};
        con.socket = try network.Socket.create(.ipv4, .tcp);
        return con;
    }

    pub fn create_ipv6() !Connection {
        var con = Connection{};
        con.socket = try network.Socket.create(.ipv6, .tcp);
        return con;
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

test "" {
    try init();
}
