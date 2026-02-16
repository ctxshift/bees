const std = @import("std");

pub const Metadata = struct {
    database: []const u8 = "bees.db",
    jsonl_export: []const u8 = "issues.jsonl",
};

pub fn write(dir: std.fs.Dir) !void {
    const content =
        \\{
        \\  "database": "bees.db",
        \\  "jsonl_export": "issues.jsonl"
        \\}
        \\
    ;
    const file = try dir.createFile("metadata.json", .{});
    defer file.close();
    try file.writeAll(content);
}

pub fn read(dir: std.fs.Dir, allocator: std.mem.Allocator) !Metadata {
    const file = dir.openFile("metadata.json", .{}) catch return Metadata{};
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 4096);
    defer allocator.free(content);

    const parsed = std.json.parseFromSlice(Metadata, allocator, content, .{ .ignore_unknown_fields = true }) catch return Metadata{};
    defer parsed.deinit();

    return .{
        .database = try allocator.dupe(u8, parsed.value.database),
        .jsonl_export = try allocator.dupe(u8, parsed.value.jsonl_export),
    };
}
