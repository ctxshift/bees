const std = @import("std");

pub const Config = struct {
    issue_prefix: ?[]const u8 = null,
    auto_start_daemon: bool = true,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        if (self.issue_prefix) |p| allocator.free(p);
    }
};

pub fn write(dir: std.fs.Dir, config: Config) !void {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    try writer.writeAll("{\n");
    if (config.issue_prefix) |prefix| {
        try writer.print("  \"issue_prefix\": \"{s}\"", .{prefix});
        try writer.writeAll("\n");
    }
    try writer.writeAll("}\n");

    const file = try dir.createFile("config.json", .{});
    defer file.close();
    try file.writeAll(fbs.getWritten());
}

pub fn read(dir: std.fs.Dir, allocator: std.mem.Allocator) !Config {
    const file = dir.openFile("config.json", .{}) catch return Config{};
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 4096);
    defer allocator.free(content);

    const parsed = std.json.parseFromSlice(Config, allocator, content, .{
        .ignore_unknown_fields = true,
    }) catch return Config{};
    defer parsed.deinit();

    return .{
        .issue_prefix = if (parsed.value.issue_prefix) |p| try allocator.dupe(u8, p) else null,
        .auto_start_daemon = parsed.value.auto_start_daemon,
    };
}
