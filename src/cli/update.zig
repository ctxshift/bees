const std = @import("std");
const clap = @import("clap");
const store_mod = @import("../db/store.zig");
const timestamp = @import("../timestamp.zig");
const io = @import("../io.zig");
const root = @import("../main.zig");

pub fn run(allocator: std.mem.Allocator, iter: anytype) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help              Show help
        \\    --title <str>       New title
        \\-s, --status <str>      New status
        \\-p, --priority <str>    New priority
        \\-a, --assignee <str>    New assignee
        \\-d, --description <str> New description
        \\-t, --type <str>        New issue type
        \\-o, --owner <str>       New owner
        \\    --json              Output as JSON
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
        try stderr.writeAll("Usage: bees update <id> [options]\n\nOptions:\n  --title <text>           New title\n  -s, --status <status>    New status\n  -p, --priority <N>       New priority\n  -a, --assignee <name>    New assignee\n  -d, --description <text> New description\n  -t, --type <type>        New issue type\n  -o, --owner <name>       New owner\n      --json               Output as JSON\n");
        return;
    }

    const issue_id = res.positionals[0] orelse {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.writeAll("Error: issue ID is required\nUsage: bees update <id> [options]\n");
        return error.MissingArgument;
    };

    const priority: ?i32 = if (res.args.priority) |p|
        std.fmt.parseInt(i32, p, 10) catch null
    else
        null;

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

    try store.updateIssue(issue_id, .{
        .title = res.args.title,
        .status = res.args.status,
        .priority = priority,
        .assignee = res.args.assignee,
        .description = res.args.description,
        .issue_type = res.args.type,
        .owner = res.args.owner,
        .updated_at = timestamp.now(),
    });

    const stdout = std.fs.File.stdout().deprecatedWriter();
    if (res.args.json != 0) {
        var json_buf: [4096]u8 = undefined;
        var json_w = io.JsonWriter.init(stdout, &json_buf);
        var jw = json_w.stringify();
        try jw.beginObject();
        try jw.objectField("id");
        try jw.write(issue_id);
        try jw.objectField("updated");
        try jw.write(true);
        try jw.endObject();
        try jw.writer.writeByte('\n');
        try jw.writer.flush();
    } else {
        try stdout.print("Updated {s}\n", .{issue_id});
    }
}
