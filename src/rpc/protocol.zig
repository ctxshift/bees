const std = @import("std");

pub const Request = struct {
    operation: []const u8,
    args: ?std.json.Value = null,
    actor: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    client_version: ?[]const u8 = null,
    expected_db: ?[]const u8 = null,
};

pub const ParsedRequest = struct {
    arena: std.heap.ArenaAllocator,
    request: Request,

    pub fn deinit(self: *ParsedRequest) void {
        self.arena.deinit();
    }
};

pub fn parseRequest(allocator: std.mem.Allocator, line: []const u8) !ParsedRequest {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), line, .{});
    const root = parsed.value;

    if (root != .object) return error.InvalidRequest;

    const operation = blk: {
        const val = root.object.get("operation") orelse return error.MissingOperation;
        if (val != .string) return error.InvalidOperation;
        break :blk val.string;
    };

    const args = root.object.get("args");
    const actor = getOptionalString(root, "actor");
    const cwd = getOptionalString(root, "cwd");
    const client_version = getOptionalString(root, "client_version");
    const expected_db = getOptionalString(root, "expected_db");

    return .{
        .arena = arena,
        .request = .{
            .operation = operation,
            .args = args,
            .actor = actor,
            .cwd = cwd,
            .client_version = client_version,
            .expected_db = expected_db,
        },
    };
}

fn getOptionalString(root: std.json.Value, key: []const u8) ?[]const u8 {
    const val = root.object.get(key) orelse return null;
    if (val != .string) return null;
    return val.string;
}

pub fn getArgString(args: ?std.json.Value, key: []const u8) ?[]const u8 {
    const a = args orelse return null;
    if (a != .object) return null;
    const val = a.object.get(key) orelse return null;
    if (val != .string) return null;
    return val.string;
}

pub fn getArgInt(args: ?std.json.Value, key: []const u8) ?i64 {
    const a = args orelse return null;
    if (a != .object) return null;
    const val = a.object.get(key) orelse return null;
    if (val != .integer) return null;
    return val.integer;
}

pub fn writeSuccess(writer: anytype, data: []const u8) !void {
    try writer.writeAll("{\"success\":true,\"data\":");
    try writer.writeAll(data);
    try writer.writeAll("}\n");
}

pub fn writeError(writer: anytype, message: []const u8) !void {
    // Need to JSON-escape the message
    try writer.writeAll("{\"success\":false,\"error\":\"");
    for (message) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
    try writer.writeAll("\"}\n");
}

test "parseRequest basic" {
    const line = "{\"operation\":\"ping\"}";
    var pr = try parseRequest(std.testing.allocator, line);
    defer pr.deinit();
    try std.testing.expectEqualStrings("ping", pr.request.operation);
    try std.testing.expect(pr.request.args == null);
}

test "parseRequest with args" {
    const line = "{\"operation\":\"list\",\"args\":{\"status\":\"open\"},\"actor\":\"user1\"}";
    var pr = try parseRequest(std.testing.allocator, line);
    defer pr.deinit();
    try std.testing.expectEqualStrings("list", pr.request.operation);
    try std.testing.expectEqualStrings("user1", pr.request.actor.?);

    const status = getArgString(pr.request.args, "status");
    try std.testing.expectEqualStrings("open", status.?);
}

test "writeSuccess" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeSuccess(fbs.writer(), "{\"message\":\"pong\"}");
    try std.testing.expectEqualStrings("{\"success\":true,\"data\":{\"message\":\"pong\"}}\n", fbs.getWritten());
}

test "writeError" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeError(fbs.writer(), "not found");
    try std.testing.expectEqualStrings("{\"success\":false,\"error\":\"not found\"}\n", fbs.getWritten());
}
