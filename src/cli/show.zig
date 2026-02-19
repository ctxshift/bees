const std = @import("std");
const clap = @import("clap");
const store_mod = @import("../db/store.zig");
const io = @import("../io.zig");
const root = @import("../main.zig");
const colors = @import("../colors.zig");

pub fn run(allocator: std.mem.Allocator, iter: anytype) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help   Show help
        \\    --json   Output as JSON
        \\<str>
        \\
    );

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        try diag.reportToFile(.stderr(), err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        const stderr = io.stderr();
        try stderr.writeAll("Usage: bees show <id> [--json]\n");
        return;
    }

    const issue_id = res.positionals[0] orelse {
        const stderr = io.stderr();
        try stderr.writeAll("Error: issue ID is required\nUsage: bees show <id>\n");
        return error.MissingArgument;
    };

    var db = try root.openDb(allocator);
    defer db.close();

    var store = store_mod.Store.init(db);

    var issue = (try store.getIssue(allocator, issue_id)) orelse {
        const stderr = io.stderr();
        try stderr.print("Error: issue '{s}' not found\n", .{issue_id});
        return error.NotFound;
    };
    defer issue.deinit(allocator);

    const labels = try store.listLabels(allocator, issue_id);
    defer {
        for (labels) |l| allocator.free(l);
        allocator.free(labels);
    }

    const deps = try store.listDeps(allocator, issue_id);
    defer {
        for (deps) |*d| d.deinit(allocator);
        allocator.free(deps);
    }

    const dependents = try store.listDependents(allocator, issue_id);
    defer {
        for (dependents) |*d| d.deinit(allocator);
        allocator.free(dependents);
    }

    const comments = try store.listComments(allocator, issue_id);
    defer {
        for (comments) |*c| c.deinit(allocator);
        allocator.free(comments);
    }

    const stdout = io.stdout();

    if (res.args.json != 0) {
        var json_buf: [4096]u8 = undefined;
        var json_w = io.JsonWriter.init(stdout, &json_buf);
        var jw = json_w.stringify();
        try issue.jsonStringify(&jw);
        try jw.writer.writeByte('\n');
        try jw.writer.flush();
        return;
    }

    // --- Human-readable output matching beads format ---

    var type_buf: [16]u8 = undefined;
    const type_upper = asciiUpper(issue.issue_type, &type_buf);
    var status_buf: [16]u8 = undefined;
    const status_upper = asciiUpper(issue.status, &status_buf);
    const status_icon = colors.statusIcon(issue.status);
    const priority_str = priorityStr(issue.priority);

    // Header line: ○ bees-4 [EPIC] · Title   [● P2 · OPEN]
    try stdout.print("\n{s} {s} [{s}] {s} {s}   [{s} {s} {s} {s}]\n", .{
        status_icon,
        issue.id,
        type_upper,
        colors.dot,
        issue.title,
        colors.priority_dot,
        priority_str,
        colors.dot,
        status_upper,
    });

    // Metadata line: Owner: X · Assignee: Y · Type: type
    {
        var has_prev = false;
        if (issue.assignee) |v| {
            try stdout.print("Assignee: {s}", .{v});
            has_prev = true;
        }
        if (issue.owner) |v| {
            if (has_prev) try stdout.print(" {s} ", .{colors.dot});
            try stdout.print("Owner: {s}", .{v});
            has_prev = true;
        }
        if (has_prev) try stdout.print(" {s} ", .{colors.dot});
        try stdout.print("Type: {s}\n", .{issue.issue_type});
    }

    // Date line: Created: YYYY-MM-DD · Updated: YYYY-MM-DD
    try stdout.print("Created: {s} {s} Updated: {s}\n", .{
        shortDate(issue.created_at),
        colors.dot,
        shortDate(issue.updated_at),
    });
    if (issue.closed_at) |v| {
        try stdout.print("Closed: {s}", .{shortDate(v)});
        if (issue.close_reason) |r| try stdout.print(" ({s})", .{r});
        try stdout.writeByte('\n');
    }
    if (issue.due_at) |v| try stdout.print("Due: {s}\n", .{shortDate(v)});
    if (issue.defer_until) |v| try stdout.print("Deferred until: {s}\n", .{shortDate(v)});
    if (issue.external_ref) |v| try stdout.print("Ref: {s}\n", .{v});

    // Content sections
    if (issue.description) |v| {
        try stdout.print("\nDESCRIPTION\n{s}\n", .{v});
    }
    if (issue.design) |v| {
        try stdout.print("\nDESIGN\n{s}\n", .{v});
    }
    if (issue.acceptance_criteria) |v| {
        try stdout.print("\nACCEPTANCE CRITERIA\n{s}\n", .{v});
    }
    if (issue.notes) |v| {
        try stdout.print("\nNOTES\n{s}\n", .{v});
    }

    // Labels
    if (labels.len > 0) {
        try stdout.writeAll("\nLABELS: ");
        for (labels, 0..) |label, i| {
            if (i > 0) try stdout.writeAll(", ");
            try stdout.writeAll(label);
        }
        try stdout.writeByte('\n');
    }

    // Dependencies (what this issue depends on)
    if (deps.len > 0) {
        // Separate parent from blocking deps
        var has_parent = false;
        var has_blocking = false;
        for (deps) |dep| {
            if (std.mem.eql(u8, dep.dep_type, "parent-child")) {
                has_parent = true;
            } else {
                has_blocking = true;
            }
        }
        if (has_parent) {
            try stdout.writeAll("\nPARENT\n");
            for (deps) |dep| {
                if (std.mem.eql(u8, dep.dep_type, "parent-child")) {
                    try stdout.print("  {s} {s}\n", .{ colors.arrow, dep.depends_on_id });
                }
            }
        }
        if (has_blocking) {
            try stdout.writeAll("\nDEPENDS ON\n");
            for (deps) |dep| {
                if (!std.mem.eql(u8, dep.dep_type, "parent-child")) {
                    try stdout.print("  {s} {s} ({s})\n", .{ colors.arrow, dep.depends_on_id, dep.dep_type });
                }
            }
        }
    }

    // Dependents (what depends on this issue) - grouped by type
    if (dependents.len > 0) {
        var has_children = false;
        var has_blocks = false;
        var has_related = false;
        for (dependents) |dep| {
            if (std.mem.eql(u8, dep.dep_type, "parent-child")) has_children = true
            else if (std.mem.eql(u8, dep.dep_type, "blocks")) has_blocks = true
            else has_related = true;
        }

        if (has_children) {
            try stdout.writeAll("\nCHILDREN\n");
            for (dependents) |dep| {
                if (std.mem.eql(u8, dep.dep_type, "parent-child")) {
                    try writeDepLine(allocator, stdout, &store, dep.issue_id);
                }
            }
        }
        if (has_blocks) {
            try stdout.writeAll("\nBLOCKS\n");
            for (dependents) |dep| {
                if (std.mem.eql(u8, dep.dep_type, "blocks")) {
                    try writeDepLine(allocator, stdout, &store, dep.issue_id);
                }
            }
        }
        if (has_related) {
            try stdout.writeAll("\nRELATED\n");
            for (dependents) |dep| {
                if (!std.mem.eql(u8, dep.dep_type, "parent-child") and !std.mem.eql(u8, dep.dep_type, "blocks")) {
                    try writeDepLine(allocator, stdout, &store, dep.issue_id);
                }
            }
        }
    }

    // Comments
    if (comments.len > 0) {
        try stdout.writeAll("\nCOMMENTS\n");
        for (comments) |comment| {
            const author = comment.author orelse "anonymous";
            try stdout.print("  [{s}] {s}: {s}\n", .{ shortDate(comment.created_at), author, comment.text });
        }
    }

    try stdout.writeByte('\n');
}

/// Write a child/dependent line: `  ↳ ✓ bees-1: Title ● P2`
fn writeDepLine(allocator: std.mem.Allocator, stdout: anytype, store: *store_mod.Store, dep_id: []const u8) !void {
    var child = (try store.getIssue(allocator, dep_id)) orelse {
        // Issue not found (deleted?), show just the ID
        try stdout.print("  {s} {s}\n", .{ colors.arrow, dep_id });
        return;
    };
    defer child.deinit(allocator);

    const icon = colors.statusIcon(child.status);
    const p_str = priorityStr(child.priority);
    try stdout.print("  {s} {s} {s}: {s} {s} {s}\n", .{
        colors.arrow,
        icon,
        child.id,
        child.title,
        colors.priority_dot,
        p_str,
    });
}

fn priorityStr(priority: i32) []const u8 {
    return switch (priority) {
        0 => "P0",
        1 => "P1",
        2 => "P2",
        3 => "P3",
        4 => "P4",
        else => "P?",
    };
}

/// Return the YYYY-MM-DD prefix of an ISO 8601 timestamp.
fn shortDate(ts: []const u8) []const u8 {
    if (ts.len >= 10) return ts[0..10];
    return ts;
}

/// Uppercase an ASCII string into a caller-provided buffer. Returns slice of the buffer.
fn asciiUpper(s: []const u8, buf: []u8) []const u8 {
    const len = @min(s.len, buf.len);
    for (s[0..len], 0..) |c, i| {
        buf[i] = if (c >= 'a' and c <= 'z') c - 32 else c;
    }
    return buf[0..len];
}
