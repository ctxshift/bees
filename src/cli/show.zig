const std = @import("std");
const clap = @import("clap");
const store_mod = @import("../db/store.zig");
const io = @import("../io.zig");
const root = @import("../main.zig");

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
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.writeAll("Usage: bees show <id> [--json]\n");
        return;
    }

    const issue_id = res.positionals[0] orelse {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.writeAll("Error: issue ID is required\nUsage: bees show <id>\n");
        return error.MissingArgument;
    };

    var db = try root.openDb(allocator);
    defer db.close();

    var store = store_mod.Store.init(db);

    var issue = (try store.getIssue(allocator, issue_id)) orelse {
        const stderr = std.fs.File.stderr().deprecatedWriter();
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

    const stdout = std.fs.File.stdout().deprecatedWriter();

    if (res.args.json != 0) {
        var json_buf: [4096]u8 = undefined;
        var json_w = io.JsonWriter.init(stdout, &json_buf);
        var jw = json_w.stringify();
        try issue.jsonStringify(&jw);
        try jw.writer.writeByte('\n');
        try jw.writer.flush();
    } else {
        // Human-readable output
        try stdout.print("{s}\n", .{issue.id});
        try stdout.print("Title:       {s}\n", .{issue.title});
        try stdout.print("Status:      {s}\n", .{issue.status});
        try stdout.print("Type:        {s}\n", .{issue.issue_type});
        try stdout.print("Priority:    {d}\n", .{issue.priority});
        if (issue.assignee) |v| try stdout.print("Assignee:    {s}\n", .{v});
        if (issue.owner) |v| try stdout.print("Owner:       {s}\n", .{v});
        if (issue.description) |v| try stdout.print("Description: {s}\n", .{v});
        if (issue.design) |v| try stdout.print("Design:      {s}\n", .{v});
        if (issue.acceptance_criteria) |v| try stdout.print("Acceptance:  {s}\n", .{v});
        if (issue.notes) |v| try stdout.print("Notes:       {s}\n", .{v});
        if (issue.external_ref) |v| try stdout.print("External:    {s}\n", .{v});
        if (issue.due_at) |v| try stdout.print("Due:         {s}\n", .{v});
        if (issue.defer_until) |v| try stdout.print("Defer until: {s}\n", .{v});
        try stdout.print("Created:     {s}\n", .{issue.created_at});
        try stdout.print("Updated:     {s}\n", .{issue.updated_at});
        if (issue.closed_at) |v| try stdout.print("Closed:      {s}\n", .{v});
        if (issue.close_reason) |v| try stdout.print("Reason:      {s}\n", .{v});

        if (labels.len > 0) {
            try stdout.writeAll("Labels:      ");
            for (labels, 0..) |label, i| {
                if (i > 0) try stdout.writeAll(", ");
                try stdout.writeAll(label);
            }
            try stdout.writeByte('\n');
        }

        if (deps.len > 0) {
            try stdout.writeAll("Depends on:\n");
            for (deps) |dep| {
                try stdout.print("  {s} ({s})\n", .{ dep.depends_on_id, dep.dep_type });
            }
        }

        if (dependents.len > 0) {
            // Group by dep_type for clearer display
            var has_children = false;
            var has_blocks = false;
            var has_related = false;
            for (dependents) |dep| {
                if (std.mem.eql(u8, dep.dep_type, "parent-child")) has_children = true;
                if (std.mem.eql(u8, dep.dep_type, "blocks")) has_blocks = true;
                if (std.mem.eql(u8, dep.dep_type, "related")) has_related = true;
            }
            if (has_children) {
                try stdout.writeAll("Children:\n");
                for (dependents) |dep| {
                    if (std.mem.eql(u8, dep.dep_type, "parent-child")) {
                        try stdout.print("  {s}\n", .{dep.issue_id});
                    }
                }
            }
            if (has_blocks) {
                try stdout.writeAll("Blocks:\n");
                for (dependents) |dep| {
                    if (std.mem.eql(u8, dep.dep_type, "blocks")) {
                        try stdout.print("  {s}\n", .{dep.issue_id});
                    }
                }
            }
            if (has_related) {
                try stdout.writeAll("Related:\n");
                for (dependents) |dep| {
                    if (std.mem.eql(u8, dep.dep_type, "related")) {
                        try stdout.print("  {s}\n", .{dep.issue_id});
                    }
                }
            }
        }

        if (comments.len > 0) {
            try stdout.writeAll("\nComments:\n");
            for (comments) |comment| {
                const author = comment.author orelse "anonymous";
                try stdout.print("  [{s}] {s}: {s}\n", .{ comment.created_at, author, comment.text });
            }
        }
    }
}
