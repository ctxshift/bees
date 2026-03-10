const std = @import("std");
const store_mod = @import("../db/store.zig");

const Store = store_mod.Store;

/// Import issues from issues.jsonl into the database.
/// Reads line-by-line, parsing each JSON object and inserting
/// the issue, its labels, and its dependencies.
/// Returns the number of issues imported.
pub fn importAll(store: *Store, allocator: std.mem.Allocator, dir: std.fs.Dir) !u32 {
    const file = dir.openFile("issues.jsonl", .{}) catch |err| {
        if (err == error.FileNotFound) return 0;
        return err;
    };
    defer file.close();

    var count: u32 = 0;
    var max_issue_num: i64 = 0;

    // Read the whole file — JSONL files are small enough
    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(content);

    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();

        const obj = switch (parsed.value) {
            .object => |o| o,
            else => continue,
        };

        const id = getStr(obj, "id") orelse continue;
        const title = getStr(obj, "title") orelse continue;

        // Track highest issue number for next_issue_number
        if (parseIssueNumber(id)) |num| {
            if (num > max_issue_num) max_issue_num = num;
        }

        // Insert the issue
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

        // Handle closed issues
        if (getStr(obj, "closed_at")) |closed_at| {
            try store.closeIssue(id, getStr(obj, "close_reason"), closed_at);
        }

        // Handle estimated_minutes via direct SQL (not in createIssue)
        if (getInt(obj, "estimated_minutes")) |mins| {
            try store.db.exec(
                "UPDATE issues SET estimated_minutes = :mins WHERE id = :id",
                .{ .mins = mins, .id = sqlite.text(id) },
            );
        }

        // Import labels
        if (obj.get("labels")) |labels_val| {
            if (labels_val == .array) {
                for (labels_val.array.items) |item| {
                    if (item == .string) {
                        store.addLabel(id, item.string, getStr(obj, "created_at") orelse "1970-01-01T00:00:00Z") catch {};
                    }
                }
            }
        }

        // Import dependencies
        if (obj.get("dependencies")) |deps_val| {
            if (deps_val == .array) {
                for (deps_val.array.items) |item| {
                    if (item != .object) continue;
                    const dep_obj = item.object;
                    const depends_on = getStr(dep_obj, "depends_on_id") orelse continue;
                    const dep_type = getStr(dep_obj, "type") orelse "blocks";
                    const dep_created = getStr(dep_obj, "created_at") orelse "1970-01-01T00:00:00Z";
                    store.addDep(id, depends_on, dep_type, dep_created) catch {};
                }
            }
        }

        count += 1;
    }

    // Update next_issue_number based on highest seen
    if (max_issue_num > 0) {
        var num_buf: [20]u8 = undefined;
        const next_str = std.fmt.bufPrint(&num_buf, "{d}", .{max_issue_num + 1}) catch unreachable;
        try store.setConfig("next_issue_number", next_str);
    }

    return count;
}

const sqlite = @import("sqlite");

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

/// Parse the numeric suffix from an issue ID like "bees-42" → 42
fn parseIssueNumber(id: []const u8) ?i64 {
    const dash_pos = std.mem.lastIndexOfScalar(u8, id, '-') orelse return null;
    if (dash_pos + 1 >= id.len) return null;
    return std.fmt.parseInt(i64, id[dash_pos + 1 ..], 10) catch null;
}
