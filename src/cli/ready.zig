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
        try stderr.writeAll("Usage: bees ready [--json]\n\nShows open issues with no unresolved blocking dependencies.\n");
        return;
    }

    var db = try root.openDb(allocator);
    defer db.close();

    var store = store_mod.Store.init(db);
    const issues = try store.listReady(allocator);
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
            try stdout.writeAll("No ready issues.\n");
            return;
        }

        const use_color = colors.shouldUseColor();

        // Header: 📋 Ready work (N issues with no blockers):
        if (use_color) {
            try stdout.print("\n{s}\xf0\x9f\x93\x8b{s} Ready work ({d} issues with no blockers):\n\n", .{
                colors.header, colors.reset, issues.len,
            });
        } else {
            try stdout.print("\n\xf0\x9f\x93\x8b Ready work ({d} issues with no blockers):\n\n", .{issues.len});
        }

        for (issues, 0..) |issue, idx| {
            const priority_str: []const u8 = switch (issue.priority) {
                0 => "P0",
                1 => "P1",
                2 => "P2",
                3 => "P3",
                4 => "P4",
                else => "P?",
            };

            const pcolor = if (use_color) colors.priorityColor(issue.priority) else "";
            const tcolor = if (use_color) colors.typeColor(issue.issue_type) else "";
            const r = if (use_color) colors.reset else "";

            // N. [● P2] [type] id: title
            try stdout.print("{d}. [{s}{s} {s}{s}] [{s}{s}{s}] {s}: {s}\n", .{
                idx + 1,
                pcolor, colors.priority_dot, priority_str, r,
                tcolor, issue.issue_type,                  r,
                issue.id,
                issue.title,
            });
        }
    }
}
