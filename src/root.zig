const std = @import("std");

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

    var request_buffer: [2048]u8 = undefined;
    const request = readRequest(&connection.stream, &request_buffer) catch {
        try respond(&connection.stream, "400 Bad Request", "bad request");
        return;
    };

    const target = extractTarget(request) catch {
        try respond(&connection.stream, "400 Bad Request", "bad request");
        return;
    };

    if (std.mem.eql(u8, target, "/v1/ping")) {
        try respond(&connection.stream, "200 OK", "pong");
        return;
    }

    try respond(&connection.stream, "404 Not Found", "not found");
}

fn readRequest(stream: *std.net.Stream, buffer: []u8) ![]const u8 {
    var used: usize = 0;
    while (true) {
        if (used == buffer.len) return error.RequestTooLarge;

        const amount = try stream.read(buffer[used..]);
        if (amount == 0) return error.UnexpectedConnectionClose;

        used += amount;
        if (std.mem.indexOf(u8, buffer[0..used], "\r\n\r\n")) |_| {
            return buffer[0..used];
        }
    }
}

fn extractTarget(request: []const u8) ![]const u8 {
    const newline_index = std.mem.indexOfScalar(u8, request, '\n') orelse
        return error.InvalidRequest;
    const first_line = std.mem.trim(u8, request[0..newline_index], " \r\n");

    const method_end = std.mem.indexOfScalar(u8, first_line, ' ') orelse
        return error.InvalidRequest;
    const method = first_line[0..method_end];
    if (!std.mem.eql(u8, method, "GET")) return error.UnsupportedMethod;

    const remainder = first_line[method_end + 1 ..];
    const target_end = std.mem.indexOfScalar(u8, remainder, ' ') orelse
        return error.InvalidRequest;

    return remainder[0..target_end];
}

fn respond(stream: *std.net.Stream, status_line: []const u8, body: []const u8) !void {
    var response_buffer: [256]u8 = undefined;
    const response = try std.fmt.bufPrint(
        &response_buffer,
        "HTTP/1.1 {s}\r\nContent-Length: {d}\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n{s}",
        .{ status_line, body.len, body },
    );

    try stream.writeAll(response);
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
