const std = @import("std");
const clap = @import("clap");
const store_mod = @import("../db/store.zig");
const timestamp = @import("../timestamp.zig");
const io = @import("../io.zig");
const root = @import("../main.zig");

pub fn run(allocator: std.mem.Allocator, iter: anytype) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help            Show help
        \\-t, --type <str>      Issue type (task, bug, feature, epic, story)
        \\-p, --priority <str>  Priority (1=critical, 2=high, 3=medium, 4=low)
        \\-a, --assignee <str>  Assignee
        \\-o, --owner <str>     Owner
        \\-d, --description <str>  Description
        \\    --design <str>    Design notes
        \\    --acceptance <str> Acceptance criteria
        \\    --notes <str>     Working notes
        \\    --external-ref <str> External reference
        \\    --due <str>       Due date (ISO 8601)
        \\    --defer <str>     Defer until date (ISO 8601)
        \\    --json            Output as JSON
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
        try stderr.writeAll(
            \\Usage: bees create <title> [options]
            \\
            \\Options:
            \\  -t, --type <type>          Issue type (task, bug, feature, epic, story)
            \\  -p, --priority <N>         Priority (1=critical, 2=high, 3=medium, 4=low)
            \\  -a, --assignee <name>      Assignee
            \\  -o, --owner <name>         Owner
            \\  -d, --description <text>   Description
            \\      --design <text>        Design notes
            \\      --acceptance <text>    Acceptance criteria
            \\      --notes <text>         Working notes
            \\      --external-ref <ref>   External reference
            \\      --due <date>           Due date (ISO 8601)
            \\      --defer <date>         Defer until date (ISO 8601)
            \\      --json                 Output as JSON
            \\
        );
        return;
    }

    const title = res.positionals[0] orelse {
        const stderr = io.stderr();
        try stderr.writeAll("Error: title is required\nUsage: bees create <title> [options]\n");
        return error.MissingArgument;
    };

    const priority: i32 = if (res.args.priority) |p|
        std.fmt.parseInt(i32, p, 10) catch 2
    else
        2;

    const issue_type = res.args.type orelse "task";

    var db = try root.openDb(allocator);
    defer db.close();

    var store = store_mod.Store.init(db);

    const id_result = try store.nextId(allocator);
    defer allocator.free(id_result.id);

    const now = timestamp.now();

    try store.createIssue(.{
        .id = id_result.id,
        .title = title,
        .description = res.args.description,
        .priority = priority,
        .issue_type = issue_type,
        .assignee = res.args.assignee,
        .owner = res.args.owner,
        .created_at = &now,
        .updated_at = &now,
        .design = res.args.design,
        .acceptance_criteria = res.args.acceptance,
        .notes = res.args.notes,
        .external_ref = res.args.@"external-ref",
        .due_at = res.args.due,
        .defer_until = res.args.@"defer",
    });

    const out = io.stdout();
    if (res.args.json != 0) {
        var json_buf: [4096]u8 = undefined;
        var json_w = io.JsonWriter.init(out, &json_buf);
        var jw = json_w.stringify();
        try jw.beginObject();
        try jw.objectField("id");
        try jw.write(id_result.id);
        try jw.objectField("title");
        try jw.write(title);
        try jw.objectField("status");
        try jw.write("open");
        try jw.objectField("priority");
        try jw.write(priority);
        try jw.objectField("issue_type");
        try jw.write(issue_type);
        try jw.endObject();
        try jw.writer.writeByte('\n');
        try jw.writer.flush();
    } else {
        try out.print("Created {s}: {s}\n", .{ id_result.id, title });
    }
}
