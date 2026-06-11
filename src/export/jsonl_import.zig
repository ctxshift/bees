const std = @import("std");
const store_mod = @import("../db/store.zig");

const Store = store_mod.Store;
const sqlite = @import("sqlite");

/// Import issues from issues.jsonl into the database.
///
/// Two-pass + transactional so the full graph round-trips:
///   pass 1 inserts every issue row, pass 2 wires up dependencies, labels,
///   and comments. Doing issues first means a dependency that references an
///   issue appearing *later* in the file no longer fails the
///   `depends_on_id REFERENCES issues(id)` foreign key (the bug that silently
///   dropped dependencies touching closed issues). The whole import runs in
///   one transaction: a duplicate id or other constraint error rolls back the
///   entire import instead of leaving a half-populated db behind.
///
/// Returns the number of issues imported.
pub fn importAll(store: *Store, allocator: std.mem.Allocator, dir: std.fs.Dir) !u32 {
    const file = dir.openFile("issues.jsonl", .{}) catch |err| {
        if (err == error.FileNotFound) return 0;
        return err;
    };
    defer file.close();

    const stderr = std.fs.File.stderr().deprecatedWriter();

    // Read the whole file — JSONL files are small enough.
    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(content);

    // Parse and validate every line up front, keeping the parsed values alive
    // for both passes. Bad lines are reported with their line number; a
    // duplicate id aborts before we touch the database.
    var parsed_list = std.ArrayList(std.json.Parsed(std.json.Value)){};
    defer {
        for (parsed_list.items) |p| p.deinit();
        parsed_list.deinit(allocator);
    }

    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    var line_no: u32 = 0;
    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        line_no += 1;
        if (line.len == 0) continue;

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
            stderr.print("Error: malformed JSON on line {d} of issues.jsonl\n", .{line_no}) catch {};
            return error.InvalidJsonl;
        };

        const obj = switch (parsed.value) {
            .object => |o| o,
            else => {
                parsed.deinit();
                continue;
            },
        };

        const id = getStr(obj, "id") orelse {
            parsed.deinit();
            continue;
        };
        if (getStr(obj, "title") == null) {
            stderr.print("Error: issue '{s}' on line {d} has no title\n", .{ id, line_no }) catch {};
            parsed.deinit();
            return error.InvalidJsonl;
        }
        if (seen.contains(id)) {
            stderr.print("Error: duplicate issue id '{s}' on line {d} of issues.jsonl\n", .{ id, line_no }) catch {};
            parsed.deinit();
            return error.DuplicateId;
        }
        try seen.put(id, {});
        try parsed_list.append(allocator, parsed);
    }

    // One transaction wraps both passes: any failure rolls the whole thing back.
    try store.db.exec("BEGIN", .{});
    errdefer store.db.exec("ROLLBACK", .{}) catch {};

    var count: u32 = 0;
    var max_issue_num: i64 = 0;

    // Pass 1: insert every issue row.
    for (parsed_list.items) |parsed| {
        const obj = parsed.value.object;
        const id = getStr(obj, "id").?;
        const title = getStr(obj, "title").?;

        if (parseIssueNumber(id)) |num| {
            if (num > max_issue_num) max_issue_num = num;
        }

        try store.createIssue(.{
            .id = id,
            .title = title,
            .description = getStr(obj, "description"),
            .status = getStr(obj, "status") orelse "open",
            .priority = getInt(obj, "priority") orelse 2,
            .issue_type = getStr(obj, "issue_type") orelse "task",
            .assignee = getStr(obj, "assignee"),
            .owner = getStr(obj, "owner"),
            .created_by = getStr(obj, "created_by"),
            .created_at = getStr(obj, "created_at") orelse "1970-01-01T00:00:00Z",
            .updated_at = getStr(obj, "updated_at") orelse "1970-01-01T00:00:00Z",
            .design = getStr(obj, "design"),
            .acceptance_criteria = getStr(obj, "acceptance_criteria"),
            .notes = getStr(obj, "notes"),
            .external_ref = getStr(obj, "external_ref"),
            .due_at = getStr(obj, "due_at"),
            .defer_until = getStr(obj, "defer_until"),
        });

        // Fields not covered by createIssue, applied via direct UPDATE.
        if (getInt(obj, "estimated_minutes")) |mins| {
            try store.db.exec(
                "UPDATE issues SET estimated_minutes = :v WHERE id = :id",
                .{ .v = mins, .id = sqlite.text(id) },
            );
        }
        if (getBool(obj, "pinned")) {
            try store.db.exec("UPDATE issues SET pinned = 1 WHERE id = :id", .{ .id = sqlite.text(id) });
        }
        if (getBool(obj, "is_template")) {
            try store.db.exec("UPDATE issues SET is_template = 1 WHERE id = :id", .{ .id = sqlite.text(id) });
        }
        if (getBool(obj, "ephemeral")) {
            try store.db.exec("UPDATE issues SET ephemeral = 1 WHERE id = :id", .{ .id = sqlite.text(id) });
        }
        if (getStr(obj, "metadata")) |m| {
            try store.db.exec(
                "UPDATE issues SET metadata = :v WHERE id = :id",
                .{ .v = sqlite.text(m), .id = sqlite.text(id) },
            );
        }

        // Closing stamps closed_at/close_reason; do it after the row exists.
        if (getStr(obj, "closed_at")) |closed_at| {
            try store.closeIssue(id, getStr(obj, "close_reason"), closed_at);
        }

        count += 1;
    }

    // Pass 2: every issue now exists, so dependencies/labels/comments wire up
    // without tripping foreign keys regardless of file ordering.
    for (parsed_list.items) |parsed| {
        const obj = parsed.value.object;
        const id = getStr(obj, "id").?;

        if (obj.get("labels")) |labels_val| {
            if (labels_val == .array) {
                for (labels_val.array.items) |item| {
                    if (item == .string) {
                        try store.addLabel(id, item.string, getStr(obj, "created_at") orelse "1970-01-01T00:00:00Z");
                    }
                }
            }
        }

        if (obj.get("dependencies")) |deps_val| {
            if (deps_val == .array) {
                for (deps_val.array.items) |item| {
                    if (item != .object) continue;
                    const dep_obj = item.object;
                    const depends_on = getStr(dep_obj, "depends_on_id") orelse continue;
                    const dep_type = getStr(dep_obj, "type") orelse "blocks";
                    const dep_created = getStr(dep_obj, "created_at") orelse "1970-01-01T00:00:00Z";
                    store.addDep(id, depends_on, dep_type, dep_created) catch {
                        stderr.print("Warning: dependency {s} -> {s} references a missing issue; skipped\n", .{ id, depends_on }) catch {};
                    };
                }
            }
        }

        if (obj.get("comments")) |comments_val| {
            if (comments_val == .array) {
                for (comments_val.array.items) |item| {
                    if (item != .object) continue;
                    const c = item.object;
                    const text = getStr(c, "text") orelse continue;
                    const c_created = getStr(c, "created_at") orelse "1970-01-01T00:00:00Z";
                    try store.addComment(id, getStr(c, "author"), text, c_created);
                }
            }
        }
    }

    // Continue numbering past the highest id seen.
    if (max_issue_num > 0) {
        var num_buf: [20]u8 = undefined;
        const next_str = std.fmt.bufPrint(&num_buf, "{d}", .{max_issue_num + 1}) catch unreachable;
        try store.setConfig("next_issue_number", next_str);
    }

    try store.db.exec("COMMIT", .{});

    return count;
}

fn getStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

fn getInt(obj: std.json.ObjectMap, key: []const u8) ?i32 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .integer => |i| @intCast(i),
        else => null,
    };
}

/// Read a boolean flag that may be serialized as a JSON bool or an integer.
fn getBool(obj: std.json.ObjectMap, key: []const u8) bool {
    const val = obj.get(key) orelse return false;
    return switch (val) {
        .bool => |b| b,
        .integer => |i| i != 0,
        else => false,
    };
}

/// Parse the numeric suffix from an issue ID like "bees-42" → 42
fn parseIssueNumber(id: []const u8) ?i64 {
    const dash_pos = std.mem.lastIndexOfScalar(u8, id, '-') orelse return null;
    if (dash_pos + 1 >= id.len) return null;
    return std.fmt.parseInt(i64, id[dash_pos + 1 ..], 10) catch null;
}
