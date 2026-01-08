const std = @import("std");
const http = std.http;

pub const PingServer = struct {
    listener: std.net.Server,

    pub fn init(listen_address: std.net.Address) !PingServer {
        return .{
            .listener = try std.net.Address.listen(listen_address, .{ .reuse_address = true }),
        };
    }

    pub fn address(self: *const PingServer) std.net.Address {
        return self.listener.listen_address;
    }

    pub fn deinit(self: *PingServer) void {
        self.listener.deinit();
    }

    pub fn run(self: *PingServer, max_requests: ?usize) !void {
        var handled: usize = 0;
        while (true) {
            if (max_requests) |limit| {
                if (handled >= limit) break;
            }

            var connection = try self.listener.accept();
            defer connection.stream.close();

            try handleConnection(&connection);
            handled += 1;
        }
    }
};

pub fn main() !void {
    var server = try PingServer.init(try std.net.Address.parseIp4("0.0.0.0", 8080));
    defer server.deinit();

    std.log.info("listening on 0.0.0.0:{d}", .{server.address().getPort()});
    try server.run(null);
}

fn handleConnection(connection: *std.net.Server.Connection) !void {
    var read_buffer: [8192]u8 = undefined;
    var write_buffer: [4096]u8 = undefined;

    var reader_state = connection.stream.reader(&read_buffer);
    var writer_state = connection.stream.writer(&write_buffer);
    var server = http.Server.init(reader_state.interface(), &writer_state.interface);

    while (true) {
        var request = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => break,
            else => return err,
        };

        const is_ping = std.mem.eql(u8, request.head.target, "/v1/ping");
        const keep_alive = request.head.keep_alive and is_ping;
        const headers = [_]http.Header{.{ .name = "content-type", .value = "text/plain" }};
        const body = if (is_ping) "pong" else "not found";
        const status = if (is_ping) http.Status.ok else http.Status.not_found;

        try request.respond(body, .{
            .status = status,
            .extra_headers = &headers,
            .keep_alive = keep_alive,
            .version = request.head.version,
        });

        if (!keep_alive) break;
    }
}

fn runServerThread(server: *PingServer) void {
    server.run(1) catch |err| std.debug.panic("server error: {s}", .{@errorName(err)});
}

fn sendPing(allocator: std.mem.Allocator, port: u16) ![]u8 {
    const address = try std.net.Address.parseIp4("127.0.0.1", port);
    var stream = try std.net.tcpConnectToAddress(address);
    defer stream.close();

    const request = "GET /v1/ping HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
    try stream.writeAll(request);

    var buffer = try std.ArrayList(u8).initCapacity(allocator, 0);
    errdefer buffer.deinit(allocator);

    var temp: [512]u8 = undefined;
    while (true) {
        const bytes_read = try stream.read(&temp);
        if (bytes_read == 0) break;
        try buffer.appendSlice(allocator, temp[0..bytes_read]);
    }

    return buffer.toOwnedSlice(allocator);
}

test "ping endpoint returns pong" {
    var server = try PingServer.init(try std.net.Address.parseIp4("127.0.0.1", 0));
    defer server.deinit();

    const port = server.address().getPort();
    const thread = try std.Thread.spawn(.{}, runServerThread, .{&server});
    defer thread.join();

    const response = try sendPing(std.testing.allocator, port);
    defer std.testing.allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "HTTP/1.1 200") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "pong") != null);
}
