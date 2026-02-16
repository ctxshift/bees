const std = @import("std");
const clap = @import("clap");
const store_mod = @import("../db/store.zig");
const root = @import("../main.zig");

pub fn run(allocator: std.mem.Allocator, iter: anytype) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help   Show help
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
        try stderr.writeAll("Usage: bees prime\n\nDumps all open issues as context for AI agents.\n");
        return;
    }

    var db = try root.openDb(allocator);
    defer db.close();

    var store = store_mod.Store.init(db);

    // Get all open issues
    const issues = try store.listIssues(allocator, .{ .status = "open" });
    defer {
        for (issues) |*issue| issue.deinit(allocator);
        allocator.free(issues);
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();

    try stdout.writeAll("# Project Issues\n\n");

    if (issues.len == 0) {
        try stdout.writeAll("No open issues.\n");
        return;
    }

    for (issues) |issue| {
        try stdout.print("## {s}: {s}\n", .{ issue.id, issue.title });
        try stdout.print("- Status: {s}\n", .{issue.status});
        try stdout.print("- Priority: {d}\n", .{issue.priority});
        try stdout.print("- Type: {s}\n", .{issue.issue_type});
        if (issue.assignee) |v| try stdout.print("- Assignee: {s}\n", .{v});
        if (issue.description) |v| try stdout.print("- Description: {s}\n", .{v});
        try stdout.writeByte('\n');
    }
}
