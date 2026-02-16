const std = @import("std");
const clap = @import("clap");
const store_mod = @import("../db/store.zig");
const io = @import("../io.zig");
const root = @import("../main.zig");

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

        for (issues) |issue| {
            const priority_str: []const u8 = switch (issue.priority) {
                1 => "P1",
                2 => "P2",
                3 => "P3",
                4 => "P4",
                else => "P?",
            };
            try stdout.print("{s:<12} {s:<3} {s:<8} {s}\n", .{
                issue.id,
                priority_str,
                issue.issue_type,
                issue.title,
            });
        }
        try stdout.print("\n{d} ready issue(s)\n", .{issues.len});
    }
}
