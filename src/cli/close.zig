const std = @import("std");
const clap = @import("clap");
const store_mod = @import("../db/store.zig");
const timestamp = @import("../timestamp.zig");
const io = @import("../io.zig");
const root = @import("../main.zig");

pub fn run(allocator: std.mem.Allocator, iter: anytype) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help           Show help
        \\-r, --reason <str>   Close reason
        \\    --json           Output as JSON
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
        try stderr.writeAll("Usage: bees close <id> [--reason <text>] [--json]\n");
        return;
    }

    const issue_id = res.positionals[0] orelse {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.writeAll("Error: issue ID is required\nUsage: bees close <id>\n");
        return error.MissingArgument;
    };

    var db = try root.openDb(allocator);
    defer db.close();

    var store = store_mod.Store.init(db);

    // Verify issue exists
    var existing = (try store.getIssue(allocator, issue_id)) orelse {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.print("Error: issue '{s}' not found\n", .{issue_id});
        return error.NotFound;
    };
    existing.deinit(allocator);

    const now = timestamp.now();
    try store.closeIssue(issue_id, res.args.reason, &now);

    const stdout = std.fs.File.stdout().deprecatedWriter();
    if (res.args.json != 0) {
        var json_buf: [4096]u8 = undefined;
        var json_w = io.JsonWriter.init(stdout, &json_buf);
        var jw = json_w.stringify();
        try jw.beginObject();
        try jw.objectField("id");
        try jw.write(issue_id);
        try jw.objectField("status");
        try jw.write("closed");
        try jw.endObject();
        try jw.writer.writeByte('\n');
        try jw.writer.flush();
    } else {
        try stdout.print("Closed {s}\n", .{issue_id});
    }
}
