const std = @import("std");
const clap = @import("clap");
const store_mod = @import("../db/store.zig");
const io = @import("../io.zig");
const root = @import("../main.zig");

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
            try issue.jsonStringify(&jw);
        }
        try jw.endArray();
        try jw.writer.writeByte('\n');
        try jw.writer.flush();
    } else {
        if (issues.len == 0) {
            try stdout.writeAll("No issues found.\n");
            return;
        }

        // Table output
        for (issues) |issue| {
            const priority_str: []const u8 = switch (issue.priority) {
                1 => "P1",
                2 => "P2",
                3 => "P3",
                4 => "P4",
                else => "P?",
            };
            const status_display: []const u8 = if (std.mem.eql(u8, issue.status, "in_progress"))
                "wip"
            else
                issue.status;

            try stdout.print("{s:<12} {s:<8} {s:<3} {s:<8} {s}\n", .{
                issue.id,
                status_display,
                priority_str,
                issue.issue_type,
                issue.title,
            });
        }
        try stdout.print("\n{d} issue(s)\n", .{issues.len});
    }
}
