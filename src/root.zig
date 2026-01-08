const std = @import("std");
const http = std.http;

pub const ServerOptions = struct {
    port: u16 = 8080,
};

pub const ServeOptions = struct {
    stop_after_request: bool = false,
};

pub fn start(options: ServerOptions) !void {
    var listener = try listen(options.port);
    defer listener.deinit();

    try serve(&listener, .{});
}

pub fn listen(port: u16) !std.net.Server {
    const address = try std.net.Address.parseIp4("0.0.0.0", port);
    return try address.listen(.{ .reuse_address = true });
}

pub fn serve(listener: *std.net.Server, options: ServeOptions) !void {
    while (true) {
        var connection = try listener.accept();
        handleConnection(&connection) catch |err| {
            std.log.err("failed to handle request: {s}", .{@errorName(err)});
        };

        if (options.stop_after_request) break;
    }
}

fn handleConnection(connection: *std.net.Server.Connection) !void {
    defer connection.stream.close();

    var read_buffer: [4096]u8 = undefined;
    var write_buffer: [4096]u8 = undefined;

    var reader = connection.stream.reader(&read_buffer);
    var writer = connection.stream.writer(&write_buffer);
    var server = http.Server.init(reader.interface(), &writer.interface);

    while (true) {
        var request = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => break,
            else => return err,
        };

        if (std.mem.eql(u8, request.head.target, "/v1/ping")) {
            try request.respond("pong", .{ .status = .ok, .keep_alive = false });
        } else {
            try request.respond("not found", .{ .status = .not_found, .keep_alive = false });
        }
        break;
    }
}

fn serveOnce(listener: *std.net.Server) void {
    serve(listener, .{ .stop_after_request = true }) catch |err| {
        std.log.err("server exited with error: {s}", .{@errorName(err)});
    };
}

test "ping endpoint returns pong" {
    var listener = try listen(0);
    defer listener.deinit();

    const port = listener.listen_address.getPort();
    const server_thread = try std.Thread.spawn(.{}, serveOnce, .{&listener});

    const address = try std.net.Address.parseIp4("127.0.0.1", port);
    var client_stream = try std.net.tcpConnectToAddress(address);
    defer client_stream.close();

    const request = "GET /v1/ping HTTP/1.1\r\nHost: localhost\r\n\r\n";
    try client_stream.writeAll(request);

    var response_buffer: [512]u8 = undefined;
    var received: usize = 0;
    while (received < response_buffer.len) {
        const amount = try client_stream.read(response_buffer[received..]);
        if (amount == 0) break;
        received += amount;
    }
    const response = response_buffer[0..received];

    server_thread.join();

    const first_line_end = std.mem.indexOfScalar(u8, response, '\n') orelse
        return error.MissingStatusLine;
    const status_line = std.mem.trim(u8, response[0..first_line_end], " \r\n");
    try std.testing.expect(std.mem.startsWith(u8, status_line, "HTTP/1.1 200"));

    const body_start = std.mem.indexOf(u8, response, "\r\n\r\n") orelse
        return error.MissingBody;
    const body = response[body_start + 4 ..];
    try std.testing.expectEqualStrings("pong", body);
}
