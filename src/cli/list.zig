const std = @import("std");
const clap = @import("clap");
const store_mod = @import("../db/store.zig");
const io = @import("../io.zig");
const root = @import("../main.zig");
const colors = @import("../colors.zig");

pub fn run(allocator: std.mem.Allocator, iter: anytype) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help             Show help
        \\-s, --status <str>     Filter by status
        \\-p, --priority <str>   Filter by priority
        \\-a, --assignee <str>   Filter by assignee
        \\    --json             Output as JSON
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
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.writeAll("Usage: bees list [options]\n\nOptions:\n  -s, --status <status>    Filter by status (open, in_progress, closed, deferred)\n  -p, --priority <N>       Filter by priority\n  -a, --assignee <name>    Filter by assignee\n      --json               Output as JSON array\n");
        return;
    }

    const priority: ?i32 = if (res.args.priority) |p|
        std.fmt.parseInt(i32, p, 10) catch null
    else
        null;

    var db = try root.openDb(allocator);
    defer db.close();

    var store = store_mod.Store.init(db);
    const issues = try store.listIssues(allocator, .{
        .status = res.args.status,
        .assignee = res.args.assignee,
        .priority = priority,
    });
    defer {
        for (issues) |*issue| issue.deinit(allocator);
        allocator.free(issues);
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();

    if (res.args.json != 0) {
        var json_buf: [4096]u8 = undefined;
        var json_w = io.JsonWriter.init(stdout, &json_buf);
        var jw = json_w.stringify();
        try jw.beginArray();
        for (issues) |*issue| {
            try issue.jsonStringifyOpen(&jw);

            // Labels
            const issue_labels = store.listLabels(allocator, issue.id) catch &[_][]const u8{};
            defer {
                for (issue_labels) |l| allocator.free(l);
                allocator.free(issue_labels);
            }
            try jw.objectField("labels");
            try jw.beginArray();
            for (issue_labels) |l| try jw.write(l);
            try jw.endArray();

            // Dependency/dependent/comment counts
            const dep_count = store.listDeps(allocator, issue.id) catch &[_]store_mod.DepResult{};
            defer {
                for (dep_count) |*d| d.deinit(allocator);
                allocator.free(dep_count);
            }
            const dependent_count = store.listDependents(allocator, issue.id) catch &[_]store_mod.DependentResult{};
            defer {
                for (dependent_count) |*d| d.deinit(allocator);
                allocator.free(dependent_count);
            }
            const comment_count = store.listComments(allocator, issue.id) catch &[_]store_mod.CommentResult{};
            defer {
                for (comment_count) |*c| @constCast(c).deinit(allocator);
                allocator.free(comment_count);
            }

            try jw.objectField("dependency_count");
            try jw.write(dep_count.len);
            try jw.objectField("dependent_count");
            try jw.write(dependent_count.len);
            try jw.objectField("comment_count");
            try jw.write(comment_count.len);

            try jw.endObject();
        }
        try jw.endArray();
        try jw.writer.writeByte('\n');
        try jw.writer.flush();
    } else {
        if (issues.len == 0) {
            try stdout.writeAll("No issues found.\n");
            return;
        }

        const use_color = colors.shouldUseColor();

        for (issues) |issue| {
            // Fetch labels, blocked-by deps, and blocks (reverse deps) for this issue
            const issue_labels = store.listLabels(allocator, issue.id) catch &.{};
            defer {
                for (issue_labels) |l| allocator.free(l);
                allocator.free(issue_labels);
            }

            const deps = store.listDeps(allocator, issue.id) catch &.{};
            defer {
                for (deps) |*d| d.deinit(allocator);
                allocator.free(deps);
            }

            const blocks = store.listBlocks(allocator, issue.id) catch &.{};
            defer {
                for (blocks) |b| allocator.free(b);
                allocator.free(blocks);
            }

            try writeIssueLine(stdout, issue, issue_labels, deps, blocks, use_color);
        }
    }
}

fn writeIssueLine(
    stdout: anytype,
    issue: store_mod.IssueResult,
    issue_labels: []const []const u8,
    deps: []const store_mod.DepResult,
    blocks: []const []const u8,
    use_color: bool,
) !void {
    const priority_str: []const u8 = switch (issue.priority) {
        0 => "P0",
        1 => "P1",
        2 => "P2",
        3 => "P3",
        4 => "P4",
        else => "P?",
    };

    const status_icon = colors.statusIcon(issue.status);

    if (use_color) {
        const is_closed = std.mem.eql(u8, issue.status, "closed");
        if (is_closed) {
            // Dim the entire line for closed issues
            try stdout.print("{s}{s} {s} [{s} {s}] [{s}]", .{
                colors.status_closed,
                status_icon, issue.id,
                colors.priority_dot, priority_str,
                issue.issue_type,
            });
            if (issue_labels.len > 0) {
                try stdout.writeAll(" [");
                for (issue_labels, 0..) |label, i| {
                    if (i > 0) try stdout.writeAll(" ");
                    try stdout.writeAll(label);
                }
                try stdout.writeAll("]");
            }
            try stdout.print(" - {s}", .{issue.title});
            try writeDeps(stdout, deps, blocks, false);
            try stdout.print("{s}", .{colors.reset});
        } else {
            const pcolor = colors.priorityColor(issue.priority);
            const tcolor = colors.typeColor(issue.issue_type);

            // Status icon
            try stdout.print("{s} ", .{status_icon});
            // Issue ID
            try stdout.print("{s} ", .{issue.id});
            // Priority
            try stdout.print("[{s}{s} {s}{s}] ", .{ pcolor, colors.priority_dot, priority_str, colors.reset });
            // Type
            try stdout.print("[{s}{s}{s}]", .{ tcolor, issue.issue_type, colors.reset });
            // Labels
            if (issue_labels.len > 0) {
                try stdout.writeAll(" [");
                for (issue_labels, 0..) |label, i| {
                    if (i > 0) try stdout.writeAll(" ");
                    try stdout.writeAll(label);
                }
                try stdout.writeAll("]");
            }
            // Title
            try stdout.print(" - {s}", .{issue.title});
            // Dependency info
            try writeDeps(stdout, deps, blocks, true);
        }
    } else {
        // Status icon
        try stdout.print("{s} ", .{status_icon});
        // Issue ID
        try stdout.print("{s} ", .{issue.id});
        // Priority
        try stdout.print("[{s} {s}] ", .{ colors.priority_dot, priority_str });
        // Type
        try stdout.print("[{s}]", .{issue.issue_type});
        // Labels
        if (issue_labels.len > 0) {
            try stdout.writeAll(" [");
            for (issue_labels, 0..) |label, i| {
                if (i > 0) try stdout.writeAll(" ");
                try stdout.writeAll(label);
            }
            try stdout.writeAll("]");
        }
        // Title
        try stdout.print(" - {s}", .{issue.title});
        // Dependency info
        try writeDeps(stdout, deps, blocks, false);
    }

    try stdout.writeAll("\n");
}

fn writeDeps(
    stdout: anytype,
    deps: []const store_mod.DepResult,
    blocks: []const []const u8,
    use_color: bool,
) !void {
    if (blocks.len > 0) {
        if (use_color) {
            try stdout.print(" {s}(blocks: ", .{colors.blocks_color});
        } else {
            try stdout.writeAll(" (blocks: ");
        }
        for (blocks, 0..) |id, i| {
            if (i > 0) try stdout.writeAll(", ");
            try stdout.writeAll(id);
        }
        if (use_color) {
            try stdout.print("){s}", .{colors.reset});
        } else {
            try stdout.writeAll(")");
        }
    }

    if (deps.len > 0) {
        if (use_color) {
            try stdout.print(" {s}(blocked by: ", .{colors.blocked_by_color});
        } else {
            try stdout.writeAll(" (blocked by: ");
        }
        for (deps, 0..) |dep, i| {
            if (i > 0) try stdout.writeAll(", ");
            try stdout.writeAll(dep.depends_on_id);
        }
        if (use_color) {
            try stdout.print("){s}", .{colors.reset});
        } else {
            try stdout.writeAll(")");
        }
    }
}
