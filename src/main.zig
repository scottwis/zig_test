const zig_test = @import("zig_test");

pub fn main() !void {
    try zig_test.start(.{});
}
