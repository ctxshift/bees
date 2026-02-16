const std = @import("std");

pub fn generate(prefix: []const u8, number: i64, buf: *[64]u8) []const u8 {
    const result = std.fmt.bufPrint(buf, "{s}-{d}", .{ prefix, number }) catch unreachable;
    return result;
}

test "generate" {
    var buf: [64]u8 = undefined;
    const id = generate("bee", 1, &buf);
    try std.testing.expectEqualStrings("bee-1", id);
}

test "generate large number" {
    var buf: [64]u8 = undefined;
    const id = generate("bee", 42, &buf);
    try std.testing.expectEqualStrings("bee-42", id);
}
