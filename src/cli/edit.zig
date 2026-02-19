const std = @import("std");
const clap = @import("clap");
const store_mod = @import("../db/store.zig");
const timestamp = @import("../timestamp.zig");
const io = @import("../io.zig");
const root = @import("../main.zig");

pub fn run(allocator: std.mem.Allocator, iter: anytype) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help          Show help
        \\    --design        Edit design notes
        \\    --acceptance    Edit acceptance criteria
        \\    --notes         Edit working notes
        \\    --description   Edit description (default)
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
            \\Usage: bees edit <id> [--design|--acceptance|--notes|--description]
            \\
            \\Opens $EDITOR to edit the specified field. Defaults to description.
            \\
            \\Options:
            \\      --design        Edit design notes
            \\      --acceptance    Edit acceptance criteria
            \\      --notes         Edit working notes
            \\      --description   Edit description (default)
            \\
        );
        return;
    }

    const issue_id = res.positionals[0] orelse {
        const stderr = io.stderr();
        try stderr.writeAll("Error: issue ID is required\nUsage: bees edit <id> [--design|--acceptance|--notes]\n");
        return error.MissingArgument;
    };

    const field: Field = if (res.args.design != 0)
        .design
    else if (res.args.acceptance != 0)
        .acceptance_criteria
    else if (res.args.notes != 0)
        .notes
    else
        .description;

    var db = try root.openDb(allocator);
    defer db.close();

    var store = store_mod.Store.init(db);

    var issue = (try store.getIssue(allocator, issue_id)) orelse {
        const stderr = io.stderr();
        try stderr.print("Error: issue '{s}' not found\n", .{issue_id});
        return error.NotFound;
    };
    defer issue.deinit(allocator);

    const current_value = switch (field) {
        .description => issue.description,
        .design => issue.design,
        .acceptance_criteria => issue.acceptance_criteria,
        .notes => issue.notes,
    };

    const new_value = openEditor(allocator, current_value orelse "") catch |err| {
        const stderr = io.stderr();
        try stderr.print("Error: failed to open editor: {}\n", .{err});
        return err;
    };
    defer allocator.free(new_value);

    // Check if content changed
    if (std.mem.eql(u8, new_value, current_value orelse "")) {
        const stdout = io.stdout();
        try stdout.writeAll("No changes made.\n");
        return;
    }

    const update_value = if (new_value.len == 0) null else new_value;

    var update_args = store_mod.UpdateArgs{
        .updated_at = timestamp.now(),
    };
    switch (field) {
        .description => update_args.description = update_value,
        .design => update_args.design = update_value,
        .acceptance_criteria => update_args.acceptance_criteria = update_value,
        .notes => update_args.notes = update_value,
    }
    try store.updateIssue(issue_id, update_args);

    const stdout = io.stdout();
    try stdout.print("Updated {s} on {s}\n", .{ field.label(), issue_id });
}

const Field = enum {
    description,
    design,
    acceptance_criteria,
    notes,

    fn label(self: Field) []const u8 {
        return switch (self) {
            .description => "description",
            .design => "design",
            .acceptance_criteria => "acceptance criteria",
            .notes => "notes",
        };
    }
};

fn openEditor(allocator: std.mem.Allocator, initial_content: []const u8) ![]const u8 {
    const editor = std.process.getEnvVarOwned(allocator, "EDITOR") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => try allocator.dupe(u8, "vi"),
        else => return err,
    };
    defer allocator.free(editor);

    // Create temp file
    const tmp_dir = std.fs.openDirAbsolute("/tmp", .{}) catch return error.TmpDirFailed;

    var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_file = tmp_dir.createFile("bees-edit-XXXXXX.md", .{ .read = true }) catch return error.TmpFileFailed;
    const tmp_path = tmp_dir.realpath("bees-edit-XXXXXX.md", &tmp_path_buf) catch return error.TmpFileFailed;
    errdefer tmp_dir.deleteFile("bees-edit-XXXXXX.md") catch {};

    // Write initial content
    if (initial_content.len > 0) {
        try tmp_file.writeAll(initial_content);
    }
    tmp_file.close();

    // Spawn editor via shell to handle complex $EDITOR values
    const shell_cmd = try std.fmt.allocPrint(allocator, "{s} {s}", .{ editor, tmp_path });
    defer allocator.free(shell_cmd);

    var child = std.process.Child.init(&.{ "/bin/sh", "-c", shell_cmd }, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    const term = try child.wait();

    if (term.Exited != 0) {
        tmp_dir.deleteFile("bees-edit-XXXXXX.md") catch {};
        return error.EditorFailed;
    }

    // Read back the result
    const result_file = tmp_dir.openFile("bees-edit-XXXXXX.md", .{}) catch return error.TmpFileFailed;
    defer result_file.close();
    defer tmp_dir.deleteFile("bees-edit-XXXXXX.md") catch {};

    const content = result_file.readToEndAlloc(allocator, 1024 * 1024) catch return error.ReadFailed;

    // Trim trailing whitespace
    const trimmed = std.mem.trimRight(u8, content, " \t\n\r");
    if (trimmed.len != content.len) {
        const result = try allocator.dupe(u8, trimmed);
        allocator.free(content);
        return result;
    }
    return content;
}
