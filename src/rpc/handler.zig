const std = @import("std");
const store_mod = @import("../db/store.zig");
const protocol = @import("protocol.zig");
const mutations = @import("mutations.zig");
const timestamp = @import("../timestamp.zig");
const jsonl = @import("../export/jsonl.zig");

const Store = store_mod.Store;
const Request = protocol.Request;
const MutationBuffer = mutations.MutationBuffer;
const MutationEvent = mutations.MutationEvent;
const Buf = std.ArrayList(u8);

pub const ServerState = struct {
    start_time_ms: i64,
    mutations: MutationBuffer = .{},
    bees_dir_path: []const u8,
    bees_dir: std.fs.Dir,
};

pub fn handleRequest(
    allocator: std.mem.Allocator,
    store: *Store,
    request: *const Request,
    state: *ServerState,
) ![]const u8 {
    const op = request.operation;

    const ops = std.StaticStringMap(Op).initComptime(.{
        .{ "ping", .ping },
        .{ "health", .health },
        .{ "status", .status },
        .{ "list", .list },
        .{ "show", .show },
        .{ "ready", .ready },
        .{ "stats", .stats },
        .{ "create", .create },
        .{ "update", .update },
        .{ "close", .close },
        .{ "dep_add", .dep_add },
        .{ "dep_remove", .dep_remove },
        .{ "label_add", .label_add },
        .{ "label_remove", .label_remove },
        .{ "comment_add", .comment_add },
        .{ "comment_list", .comment_list },
        .{ "get_mutations", .get_mutations },
        .{ "export", .@"export" },
        .{ "shutdown", .shutdown },
    });

    const matched = ops.get(op) orelse return try allocErr(allocator, "unknown operation");

    return switch (matched) {
        .ping => handlePing(allocator),
        .health => handleHealth(allocator, store),
        .status => handleStatus(allocator, state),
        .list => handleList(allocator, store, request.args),
        .show => handleShow(allocator, store, request.args),
        .ready => handleReady(allocator, store),
        .stats => handleStats(allocator, store),
        .create => handleCreate(allocator, store, request, state),
        .update => handleUpdate(allocator, store, request, state),
        .close => handleClose(allocator, store, request, state),
        .dep_add => handleDepAdd(allocator, store, request, state),
        .dep_remove => handleDepRemove(allocator, store, request, state),
        .label_add => handleLabelAdd(allocator, store, request, state),
        .label_remove => handleLabelRemove(allocator, store, request, state),
        .comment_add => handleCommentAdd(allocator, store, request, state),
        .comment_list => handleCommentList(allocator, store, request.args),
        .get_mutations => handleGetMutations(allocator, state, request.args),
        .@"export" => handleExport(allocator, store, state),
        .shutdown => handleShutdown(allocator),
    };
}

const Op = enum {
    ping, health, status, list, show, ready, stats,
    create, update, close, dep_add, dep_remove,
    label_add, label_remove, comment_add, comment_list,
    get_mutations, @"export", shutdown,
};

fn handlePing(allocator: std.mem.Allocator) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "{{\"message\":\"pong\",\"version\":\"0.1.0\"}}", .{});
}

fn handleHealth(allocator: std.mem.Allocator, store: *Store) ![]const u8 {
    const total = store.countTotal();
    return try std.fmt.allocPrint(allocator, "{{\"status\":\"ok\",\"total_issues\":{d}}}", .{total});
}

fn handleStatus(allocator: std.mem.Allocator, state: *ServerState) ![]const u8 {
    const now_ms = std.time.milliTimestamp();
    const uptime_s = @divTrunc(now_ms - state.start_time_ms, 1000);
    return try std.fmt.allocPrint(allocator, "{{\"running\":true,\"uptime_seconds\":{d},\"mutations_tracked\":{d}}}", .{ uptime_s, state.mutations.count });
}

fn handleList(allocator: std.mem.Allocator, store: *Store, args: ?std.json.Value) ![]const u8 {
    const filter = store_mod.ListFilter{
        .status = protocol.getArgString(args, "status"),
        .assignee = protocol.getArgString(args, "assignee"),
        .priority = if (protocol.getArgInt(args, "priority")) |p| @as(?i32, @intCast(p)) else null,
    };

    const issues = try store.listIssues(allocator, filter);
    defer {
        for (issues) |*issue| @constCast(issue).deinit(allocator);
        allocator.free(issues);
    }

    // Bulk-fetch labels and deps for hydrated responses
    const all_labels = try store.listAllLabels(allocator);
    defer {
        for (all_labels) |e| {
            allocator.free(e.issue_id);
            allocator.free(e.label);
        }
        allocator.free(all_labels);
    }

    const all_deps = try store.listAllDeps(allocator);
    defer {
        for (all_deps) |e| {
            allocator.free(e.issue_id);
            allocator.free(e.depends_on_id);
            allocator.free(e.dep_type);
        }
        allocator.free(all_deps);
    }

    var buf = Buf{};
    errdefer buf.deinit(allocator);

    try buf.append(allocator, '[');
    for (issues, 0..) |*issue, i| {
        if (i > 0) try buf.append(allocator, ',');
        try writeIssueJson(allocator, &buf, issue);
        // Remove trailing '}' to append extra fields
        _ = buf.pop();

        // Add labels for this issue
        try buf.appendSlice(allocator, ",\"labels\":[");
        var label_first = true;
        for (all_labels) |e| {
            if (std.mem.eql(u8, e.issue_id, issue.id)) {
                if (!label_first) try buf.append(allocator, ',');
                label_first = false;
                try appendJsonString(allocator, &buf, e.label);
            }
        }
        try buf.append(allocator, ']');

        // Add dependencies (blocked-by: issues this one depends on)
        try buf.appendSlice(allocator, ",\"dependencies\":[");
        var dep_first = true;
        for (all_deps) |e| {
            if (std.mem.eql(u8, e.issue_id, issue.id)) {
                if (!dep_first) try buf.append(allocator, ',');
                dep_first = false;
                // Include related issue details for the extension
                try writeDepIssueJson(allocator, &buf, e.depends_on_id, e.dep_type, store, issues);
            }
        }
        try buf.append(allocator, ']');

        // Add dependents (blocks: issues that depend on this one)
        try buf.appendSlice(allocator, ",\"dependents\":[");
        var block_first = true;
        for (all_deps) |e| {
            if (std.mem.eql(u8, e.depends_on_id, issue.id)) {
                if (!block_first) try buf.append(allocator, ',');
                block_first = false;
                try writeDepIssueJson(allocator, &buf, e.issue_id, e.dep_type, store, issues);
            }
        }
        try buf.append(allocator, ']');

        try buf.append(allocator, '}');
    }
    try buf.append(allocator, ']');

    return try buf.toOwnedSlice(allocator);
}

fn handleShow(allocator: std.mem.Allocator, store: *Store, args: ?std.json.Value) ![]const u8 {
    const id = protocol.getArgString(args, "id") orelse
        return try allocErr(allocator, "missing required arg: id");

    const issue = (try store.getIssue(allocator, id)) orelse
        return try allocErr(allocator, "issue not found");
    defer {
        var m = issue;
        m.deinit(allocator);
    }

    const labels = store.listLabels(allocator, id) catch &[_][]const u8{};
    defer {
        for (labels) |l| allocator.free(l);
        allocator.free(labels);
    }

    const deps = store.listDeps(allocator, id) catch &[_]store_mod.DepResult{};
    defer {
        for (deps) |*d| @constCast(d).deinit(allocator);
        allocator.free(deps);
    }

    const comments = store.listComments(allocator, id) catch &[_]store_mod.CommentResult{};
    defer {
        for (comments) |*c| @constCast(c).deinit(allocator);
        allocator.free(comments);
    }

    var buf = Buf{};
    errdefer buf.deinit(allocator);

    try writeHydratedShowJson(allocator, &buf, &issue, labels, deps, comments);

    return try buf.toOwnedSlice(allocator);
}

fn handleReady(allocator: std.mem.Allocator, store: *Store) ![]const u8 {
    const issues = try store.listReady(allocator);
    defer {
        for (issues) |*issue| @constCast(issue).deinit(allocator);
        allocator.free(issues);
    }

    const all_labels = try store.listAllLabels(allocator);
    defer {
        for (all_labels) |e| {
            allocator.free(e.issue_id);
            allocator.free(e.label);
        }
        allocator.free(all_labels);
    }

    const all_deps = try store.listAllDeps(allocator);
    defer {
        for (all_deps) |e| {
            allocator.free(e.issue_id);
            allocator.free(e.depends_on_id);
            allocator.free(e.dep_type);
        }
        allocator.free(all_deps);
    }

    var buf = Buf{};
    errdefer buf.deinit(allocator);

    try buf.append(allocator, '[');
    for (issues, 0..) |*issue, i| {
        if (i > 0) try buf.append(allocator, ',');
        try writeIssueJson(allocator, &buf, issue);
        _ = buf.pop();

        try buf.appendSlice(allocator, ",\"labels\":[");
        var label_first = true;
        for (all_labels) |e| {
            if (std.mem.eql(u8, e.issue_id, issue.id)) {
                if (!label_first) try buf.append(allocator, ',');
                label_first = false;
                try appendJsonString(allocator, &buf, e.label);
            }
        }
        try buf.append(allocator, ']');

        try buf.appendSlice(allocator, ",\"dependencies\":[");
        var dep_first = true;
        for (all_deps) |e| {
            if (std.mem.eql(u8, e.issue_id, issue.id)) {
                if (!dep_first) try buf.append(allocator, ',');
                dep_first = false;
                try writeDepIssueJson(allocator, &buf, e.depends_on_id, e.dep_type, store, issues);
            }
        }
        try buf.append(allocator, ']');

        try buf.appendSlice(allocator, ",\"dependents\":[");
        var block_first = true;
        for (all_deps) |e| {
            if (std.mem.eql(u8, e.depends_on_id, issue.id)) {
                if (!block_first) try buf.append(allocator, ',');
                block_first = false;
                try writeDepIssueJson(allocator, &buf, e.issue_id, e.dep_type, store, issues);
            }
        }
        try buf.append(allocator, ']');

        try buf.append(allocator, '}');
    }
    try buf.append(allocator, ']');

    return try buf.toOwnedSlice(allocator);
}

fn handleStats(allocator: std.mem.Allocator, store: *Store) ![]const u8 {
    const open_count = store.countByStatus("open");
    const in_progress_count = store.countByStatus("in_progress");
    const closed_count = store.countByStatus("closed");
    const total = store.countTotal();

    return try std.fmt.allocPrint(allocator,
        "{{\"open\":{d},\"in_progress\":{d},\"closed\":{d},\"total\":{d}}}",
        .{ open_count, in_progress_count, closed_count, total },
    );
}

fn handleCreate(allocator: std.mem.Allocator, store: *Store, request: *const Request, state: *ServerState) ![]const u8 {
    const args = request.args;
    const title = protocol.getArgString(args, "title") orelse
        return try allocErr(allocator, "missing required arg: title");

    const description = protocol.getArgString(args, "description");
    const issue_type = protocol.getArgString(args, "type") orelse
        protocol.getArgString(args, "issue_type") orelse "task";
    const assignee = protocol.getArgString(args, "assignee");
    const owner = protocol.getArgString(args, "owner");
    const created_by = request.actor;

    const priority: i32 = if (protocol.getArgInt(args, "priority")) |p| @intCast(p) else 2;

    const id_result = try store.nextId(allocator);
    defer allocator.free(id_result.id);

    const now = timestamp.now();

    try store.createIssue(.{
        .id = id_result.id,
        .title = title,
        .description = description,
        .priority = priority,
        .issue_type = issue_type,
        .assignee = assignee,
        .owner = owner,
        .created_by = created_by,
        .created_at = &now,
        .updated_at = &now,
        .design = protocol.getArgString(args, "design"),
        .acceptance_criteria = protocol.getArgString(args, "acceptance_criteria"),
        .notes = protocol.getArgString(args, "notes"),
        .external_ref = protocol.getArgString(args, "external_ref"),
        .due_at = protocol.getArgString(args, "due_at"),
        .defer_until = protocol.getArgString(args, "defer_until"),
    });

    recordMutation(state, .create, id_result.id, title);
    doExport(store, allocator, state);

    return try std.fmt.allocPrint(allocator, "{{\"id\":\"{s}\",\"title\":\"{s}\"}}", .{ id_result.id, title });
}

fn handleUpdate(allocator: std.mem.Allocator, store: *Store, request: *const Request, state: *ServerState) ![]const u8 {
    const args = request.args;
    const id = protocol.getArgString(args, "id") orelse
        return try allocErr(allocator, "missing required arg: id");

    const now = timestamp.now();

    try store.updateIssue(id, .{
        .title = protocol.getArgString(args, "title"),
        .status = protocol.getArgString(args, "status"),
        .priority = if (protocol.getArgInt(args, "priority")) |p| @as(?i32, @intCast(p)) else null,
        .assignee = protocol.getArgString(args, "assignee"),
        .description = protocol.getArgString(args, "description"),
        .issue_type = protocol.getArgString(args, "type") orelse protocol.getArgString(args, "issue_type"),
        .owner = protocol.getArgString(args, "owner"),
        .design = protocol.getArgString(args, "design"),
        .acceptance_criteria = protocol.getArgString(args, "acceptance_criteria"),
        .notes = protocol.getArgString(args, "notes"),
        .external_ref = protocol.getArgString(args, "external_ref"),
        .due_at = protocol.getArgString(args, "due_at"),
        .defer_until = protocol.getArgString(args, "defer_until"),
        .updated_at = now,
    });

    // Handle labels if provided (extension sends "set_labels", also accept "labels")
    if (args) |a| {
        if (a == .object) {
            const labels_val = a.object.get("set_labels") orelse a.object.get("labels");
            if (labels_val) |lv| {
                if (lv == .array) {
                    const existing = store.listLabels(allocator, id) catch &[_][]const u8{};
                    for (existing) |l| {
                        store.removeLabel(id, l) catch {};
                        allocator.free(l);
                    }
                    allocator.free(existing);

                    for (lv.array.items) |item| {
                        if (item == .string) {
                            store.addLabel(id, item.string, &now) catch {};
                        }
                    }
                }
            }
        }
    }

    recordMutation(state, .update, id, "");
    doExport(store, allocator, state);

    return try std.fmt.allocPrint(allocator, "{{\"id\":\"{s}\",\"updated\":true}}", .{id});
}

fn handleClose(allocator: std.mem.Allocator, store: *Store, request: *const Request, state: *ServerState) ![]const u8 {
    const args = request.args;
    const id = protocol.getArgString(args, "id") orelse
        return try allocErr(allocator, "missing required arg: id");

    const reason = protocol.getArgString(args, "reason");
    const now = timestamp.now();

    try store.closeIssue(id, reason, &now);

    recordMutation(state, .update, id, "");
    doExport(store, allocator, state);

    return try std.fmt.allocPrint(allocator, "{{\"id\":\"{s}\",\"closed\":true}}", .{id});
}

fn handleDepAdd(allocator: std.mem.Allocator, store: *Store, request: *const Request, state: *ServerState) ![]const u8 {
    const args = request.args;
    const id = protocol.getArgString(args, "id") orelse protocol.getArgString(args, "issue_id") orelse
        return try allocErr(allocator, "missing required arg: id");
    const depends_on = protocol.getArgString(args, "depends_on") orelse protocol.getArgString(args, "depends_on_id") orelse
        return try allocErr(allocator, "missing required arg: depends_on");
    const dep_type = protocol.getArgString(args, "type") orelse protocol.getArgString(args, "dep_type") orelse "blocks";

    const now = timestamp.now();
    try store.addDep(id, depends_on, dep_type, &now);

    recordMutation(state, .update, id, "");
    doExport(store, allocator, state);

    return try std.fmt.allocPrint(allocator, "{{\"id\":\"{s}\",\"depends_on\":\"{s}\",\"added\":true}}", .{ id, depends_on });
}

fn handleDepRemove(allocator: std.mem.Allocator, store: *Store, request: *const Request, state: *ServerState) ![]const u8 {
    const args = request.args;
    const id = protocol.getArgString(args, "id") orelse protocol.getArgString(args, "issue_id") orelse
        return try allocErr(allocator, "missing required arg: id");
    const depends_on = protocol.getArgString(args, "depends_on") orelse protocol.getArgString(args, "depends_on_id") orelse
        return try allocErr(allocator, "missing required arg: depends_on");

    try store.removeDep(id, depends_on);

    recordMutation(state, .update, id, "");
    doExport(store, allocator, state);

    return try std.fmt.allocPrint(allocator, "{{\"id\":\"{s}\",\"depends_on\":\"{s}\",\"removed\":true}}", .{ id, depends_on });
}

fn handleLabelAdd(allocator: std.mem.Allocator, store: *Store, request: *const Request, state: *ServerState) ![]const u8 {
    const args = request.args;
    const id = protocol.getArgString(args, "id") orelse protocol.getArgString(args, "issue_id") orelse
        return try allocErr(allocator, "missing required arg: id");
    const label = protocol.getArgString(args, "label") orelse
        return try allocErr(allocator, "missing required arg: label");

    const now = timestamp.now();
    try store.addLabel(id, label, &now);

    recordMutation(state, .update, id, "");
    doExport(store, allocator, state);

    return try std.fmt.allocPrint(allocator, "{{\"id\":\"{s}\",\"label\":\"{s}\",\"added\":true}}", .{ id, label });
}

fn handleLabelRemove(allocator: std.mem.Allocator, store: *Store, request: *const Request, state: *ServerState) ![]const u8 {
    const args = request.args;
    const id = protocol.getArgString(args, "id") orelse protocol.getArgString(args, "issue_id") orelse
        return try allocErr(allocator, "missing required arg: id");
    const label = protocol.getArgString(args, "label") orelse
        return try allocErr(allocator, "missing required arg: label");

    try store.removeLabel(id, label);

    recordMutation(state, .update, id, "");
    doExport(store, allocator, state);

    return try std.fmt.allocPrint(allocator, "{{\"id\":\"{s}\",\"label\":\"{s}\",\"removed\":true}}", .{ id, label });
}

fn handleCommentAdd(allocator: std.mem.Allocator, store: *Store, request: *const Request, state: *ServerState) ![]const u8 {
    const args = request.args;
    const id = protocol.getArgString(args, "id") orelse protocol.getArgString(args, "issue_id") orelse
        return try allocErr(allocator, "missing required arg: id");
    const text = protocol.getArgString(args, "text") orelse protocol.getArgString(args, "comment") orelse
        return try allocErr(allocator, "missing required arg: text");
    const author = protocol.getArgString(args, "author") orelse request.actor;

    const now = timestamp.now();
    try store.addComment(id, author, text, &now);

    recordMutation(state, .comment, id, "");
    doExport(store, allocator, state);

    return try std.fmt.allocPrint(allocator, "{{\"id\":\"{s}\",\"added\":true}}", .{id});
}

fn handleCommentList(allocator: std.mem.Allocator, store: *Store, args: ?std.json.Value) ![]const u8 {
    const id = protocol.getArgString(args, "id") orelse protocol.getArgString(args, "issue_id") orelse
        return try allocErr(allocator, "missing required arg: id");

    const comments = try store.listComments(allocator, id);
    defer {
        for (comments) |*c| @constCast(c).deinit(allocator);
        allocator.free(comments);
    }

    var buf = Buf{};
    errdefer buf.deinit(allocator);

    try buf.append(allocator, '[');
    for (comments, 0..) |*c, i| {
        if (i > 0) try buf.append(allocator, ',');
        try appendCommentJson(allocator, &buf, c);
    }
    try buf.append(allocator, ']');

    return try buf.toOwnedSlice(allocator);
}

fn handleGetMutations(allocator: std.mem.Allocator, state: *ServerState, args: ?std.json.Value) ![]const u8 {
    const since_ms: i64 = protocol.getArgInt(args, "since") orelse 0;

    var buf = Buf{};
    errdefer buf.deinit(allocator);

    try buf.append(allocator, '[');
    var iter = state.mutations.sinceIter(since_ms);
    var first = true;
    while (iter.next()) |ev| {
        if (!first) try buf.append(allocator, ',');
        first = false;
        try buf.appendSlice(allocator, "{\"Type\":\"");
        try buf.appendSlice(allocator, ev.mutation_type.toString());
        try buf.appendSlice(allocator, "\",\"IssueID\":\"");
        try buf.appendSlice(allocator, ev.getIssueId());
        try buf.appendSlice(allocator, "\",\"Title\":");
        try appendJsonString(allocator, &buf, ev.getTitle());
        try buf.appendSlice(allocator, ",\"Assignee\":\"\",\"Actor\":\"\",\"Timestamp\":\"");
        // Convert ms timestamp to ISO 8601
        const secs = @divTrunc(ev.timestamp_ms, 1000);
        const ts = timestamp.formatUnix(secs);
        try buf.appendSlice(allocator, &ts);
        try buf.appendSlice(allocator, "\"}");
    }
    try buf.append(allocator, ']');

    return try buf.toOwnedSlice(allocator);
}

fn handleExport(allocator: std.mem.Allocator, store: *Store, state: *ServerState) ![]const u8 {
    doExport(store, allocator, state);
    return try std.fmt.allocPrint(allocator, "{{\"exported\":true}}", .{});
}

fn handleShutdown(allocator: std.mem.Allocator) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "{{\"shutting_down\":true}}", .{});
}

// --- Helpers ---

fn recordMutation(state: *ServerState, mutation_type: mutations.MutationType, issue_id: []const u8, title: []const u8) void {
    const now_ms = std.time.milliTimestamp();
    state.mutations.record(MutationEvent.init(mutation_type, issue_id, title, now_ms));
}

fn doExport(store: *Store, allocator: std.mem.Allocator, state: *ServerState) void {
    jsonl.exportAll(store, allocator, state.bees_dir) catch {};
}

fn allocErr(allocator: std.mem.Allocator, msg: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "ERR:{s}", .{msg});
}

fn writeIssueJson(allocator: std.mem.Allocator, buf: *Buf, issue: *const store_mod.IssueResult) !void {
    try buf.appendSlice(allocator, "{\"id\":\"");
    try buf.appendSlice(allocator, issue.id);
    try buf.appendSlice(allocator, "\",\"title\":");
    try appendJsonString(allocator, buf, issue.title);
    if (issue.description) |v| {
        try buf.appendSlice(allocator, ",\"description\":");
        try appendJsonString(allocator, buf, v);
    }
    try buf.appendSlice(allocator, ",\"status\":\"");
    try buf.appendSlice(allocator, issue.status);
    try buf.appendSlice(allocator, "\",\"priority\":");
    var num_buf: [20]u8 = undefined;
    const p_str = std.fmt.bufPrint(&num_buf, "{d}", .{issue.priority}) catch unreachable;
    try buf.appendSlice(allocator, p_str);
    try buf.appendSlice(allocator, ",\"issue_type\":\"");
    try buf.appendSlice(allocator, issue.issue_type);
    try buf.append(allocator, '"');
    if (issue.assignee) |v| {
        try buf.appendSlice(allocator, ",\"assignee\":\"");
        try buf.appendSlice(allocator, v);
        try buf.append(allocator, '"');
    }
    if (issue.owner) |v| {
        try buf.appendSlice(allocator, ",\"owner\":\"");
        try buf.appendSlice(allocator, v);
        try buf.append(allocator, '"');
    }
    if (issue.created_by) |v| {
        try buf.appendSlice(allocator, ",\"created_by\":\"");
        try buf.appendSlice(allocator, v);
        try buf.append(allocator, '"');
    }
    try buf.appendSlice(allocator, ",\"created_at\":\"");
    try buf.appendSlice(allocator, issue.created_at);
    try buf.appendSlice(allocator, "\",\"updated_at\":\"");
    try buf.appendSlice(allocator, issue.updated_at);
    try buf.append(allocator, '"');
    if (issue.closed_at) |v| {
        try buf.appendSlice(allocator, ",\"closed_at\":\"");
        try buf.appendSlice(allocator, v);
        try buf.append(allocator, '"');
    }
    if (issue.close_reason) |v| {
        try buf.appendSlice(allocator, ",\"close_reason\":");
        try appendJsonString(allocator, buf, v);
    }
    if (issue.due_at) |v| {
        try buf.appendSlice(allocator, ",\"due_at\":\"");
        try buf.appendSlice(allocator, v);
        try buf.append(allocator, '"');
    }
    if (issue.defer_until) |v| {
        try buf.appendSlice(allocator, ",\"defer_until\":\"");
        try buf.appendSlice(allocator, v);
        try buf.append(allocator, '"');
    }
    if (issue.estimated_minutes) |v| {
        var em_buf: [20]u8 = undefined;
        const em_str = std.fmt.bufPrint(&em_buf, "{d}", .{v}) catch unreachable;
        try buf.appendSlice(allocator, ",\"estimated_minutes\":");
        try buf.appendSlice(allocator, em_str);
    }
    if (issue.external_ref) |v| {
        try buf.appendSlice(allocator, ",\"external_ref\":\"");
        try buf.appendSlice(allocator, v);
        try buf.append(allocator, '"');
    }
    if (issue.pinned != 0) {
        try buf.appendSlice(allocator, ",\"pinned\":true");
    }
    if (issue.is_template != 0) {
        try buf.appendSlice(allocator, ",\"is_template\":true");
    }
    if (issue.ephemeral != 0) {
        try buf.appendSlice(allocator, ",\"ephemeral\":true");
    }
    if (issue.metadata) |v| {
        try buf.appendSlice(allocator, ",\"metadata\":");
        try appendJsonString(allocator, buf, v);
    }
    if (issue.design) |v| {
        try buf.appendSlice(allocator, ",\"design\":");
        try appendJsonString(allocator, buf, v);
    }
    if (issue.acceptance_criteria) |v| {
        try buf.appendSlice(allocator, ",\"acceptance_criteria\":");
        try appendJsonString(allocator, buf, v);
    }
    if (issue.notes) |v| {
        try buf.appendSlice(allocator, ",\"notes\":");
        try appendJsonString(allocator, buf, v);
    }
    try buf.append(allocator, '}');
}

fn writeHydratedShowJson(
    allocator: std.mem.Allocator,
    buf: *Buf,
    issue: *const store_mod.IssueResult,
    labels: []const []const u8,
    deps: []const store_mod.DepResult,
    comments: []const store_mod.CommentResult,
) !void {
    try writeIssueJson(allocator, buf, issue);
    // Remove trailing '}'
    _ = buf.pop();

    // Add labels
    try buf.appendSlice(allocator, ",\"labels\":[");
    for (labels, 0..) |l, i| {
        if (i > 0) try buf.append(allocator, ',');
        try appendJsonString(allocator, buf, l);
    }
    try buf.append(allocator, ']');

    // Add dependencies
    try buf.appendSlice(allocator, ",\"dependencies\":[");
    for (deps, 0..) |*d, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "{\"issue_id\":\"");
        try buf.appendSlice(allocator, issue.id);
        try buf.appendSlice(allocator, "\",\"depends_on_id\":\"");
        try buf.appendSlice(allocator, d.depends_on_id);
        try buf.appendSlice(allocator, "\",\"type\":\"");
        try buf.appendSlice(allocator, d.dep_type);
        try buf.appendSlice(allocator, "\",\"created_at\":\"");
        try buf.appendSlice(allocator, d.created_at);
        try buf.appendSlice(allocator, "\"}");
    }
    try buf.append(allocator, ']');

    // Add comments
    try buf.appendSlice(allocator, ",\"comments\":[");
    for (comments, 0..) |*c, i| {
        if (i > 0) try buf.append(allocator, ',');
        try appendCommentJson(allocator, buf, c);
    }
    try buf.append(allocator, ']');

    try buf.append(allocator, '}');
}

/// Write a dependency entry with the related issue's details (id, title, status, priority, type, dependency_type).
/// Looks up the issue from the already-fetched list first, falls back to a DB query.
fn writeDepIssueJson(
    allocator: std.mem.Allocator,
    buf: *Buf,
    related_id: []const u8,
    dep_type: []const u8,
    store: *Store,
    cached_issues: []const store_mod.IssueResult,
) !void {
    // Try to find the related issue in the cached list
    for (cached_issues) |ci| {
        if (std.mem.eql(u8, ci.id, related_id)) {
            try writeDepEntryJson(allocator, buf, related_id, ci.title, ci.status, ci.priority, ci.issue_type, dep_type);
            return;
        }
    }

    // Fallback to DB lookup if not in cached list (e.g., child not in filtered results)
    if (store.getIssue(allocator, related_id) catch null) |issue| {
        defer {
            var m = issue;
            m.deinit(allocator);
        }
        try writeDepEntryJson(allocator, buf, related_id, issue.title, issue.status, issue.priority, issue.issue_type, dep_type);
        return;
    }

    // Issue not found at all - write with empty defaults
    try writeDepEntryJson(allocator, buf, related_id, "", "open", 2, "task", dep_type);
}

fn writeDepEntryJson(
    allocator: std.mem.Allocator,
    buf: *Buf,
    id: []const u8,
    title: []const u8,
    status: []const u8,
    priority: i32,
    issue_type: []const u8,
    dep_type: []const u8,
) !void {
    try buf.appendSlice(allocator, "{\"id\":\"");
    try buf.appendSlice(allocator, id);
    try buf.appendSlice(allocator, "\",\"title\":");
    try appendJsonString(allocator, buf, title);
    try buf.appendSlice(allocator, ",\"status\":\"");
    try buf.appendSlice(allocator, status);
    try buf.appendSlice(allocator, "\",\"priority\":");
    var num_buf: [20]u8 = undefined;
    const p_str = std.fmt.bufPrint(&num_buf, "{d}", .{priority}) catch unreachable;
    try buf.appendSlice(allocator, p_str);
    try buf.appendSlice(allocator, ",\"issue_type\":\"");
    try buf.appendSlice(allocator, issue_type);
    try buf.appendSlice(allocator, "\",\"dependency_type\":\"");
    try buf.appendSlice(allocator, dep_type);
    try buf.appendSlice(allocator, "\"}");
}

fn appendCommentJson(allocator: std.mem.Allocator, buf: *Buf, c: *const store_mod.CommentResult) !void {
    try buf.appendSlice(allocator, "{\"id\":");
    var id_buf: [20]u8 = undefined;
    const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{c.id}) catch unreachable;
    try buf.appendSlice(allocator, id_str);
    if (c.author) |a| {
        try buf.appendSlice(allocator, ",\"author\":\"");
        try buf.appendSlice(allocator, a);
        try buf.append(allocator, '"');
    }
    try buf.appendSlice(allocator, ",\"text\":");
    try appendJsonString(allocator, buf, c.text);
    try buf.appendSlice(allocator, ",\"created_at\":\"");
    try buf.appendSlice(allocator, c.created_at);
    try buf.appendSlice(allocator, "\"}");
}

fn appendJsonString(allocator: std.mem.Allocator, buf: *Buf, s: []const u8) !void {
    try buf.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    var esc_buf: [6]u8 = undefined;
                    const esc = std.fmt.bufPrint(&esc_buf, "\\u{x:0>4}", .{c}) catch unreachable;
                    try buf.appendSlice(allocator, esc);
                } else {
                    try buf.append(allocator, c);
                }
            },
        }
    }
    try buf.append(allocator, '"');
}

pub fn isError(response: []const u8) bool {
    return std.mem.startsWith(u8, response, "ERR:");
}

pub fn errorMessage(response: []const u8) []const u8 {
    if (std.mem.startsWith(u8, response, "ERR:")) {
        return response[4..];
    }
    return response;
}

pub fn isShutdown(response: []const u8) bool {
    return std.mem.indexOf(u8, response, "shutting_down") != null;
}
