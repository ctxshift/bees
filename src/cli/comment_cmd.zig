const std = @import("std");
const clap = @import("clap");
const store_mod = @import("../db/store.zig");
const timestamp = @import("../timestamp.zig");
const io = @import("../io.zig");
const root = @import("../main.zig");

pub fn run(allocator: std.mem.Allocator, iter: anytype) !void {
    const subcmd = iter.next() orelse {
        const stderr = io.stderr();
        try stderr.writeAll("Usage: bees comment <add|list> <issue-id> [options]\n");
        return error.MissingArgument;
    };

    if (std.mem.eql(u8, subcmd, "add")) {
        try runAdd(allocator, iter);
    } else if (std.mem.eql(u8, subcmd, "list")) {
        try runList(allocator, iter);
    } else if (std.mem.eql(u8, subcmd, "--help") or std.mem.eql(u8, subcmd, "-h")) {
        const stderr = io.stderr();
        try stderr.writeAll(
            \\Usage: bees comment <subcommand> [options]
            \\
            \\Subcommands:
            \\  add <issue-id> <text>    Add a comment to an issue
            \\  list <issue-id>          List comments on an issue
            \\
        );
    } else {
        const stderr = io.stderr();
        try stderr.print("Unknown comment subcommand: {s}\n", .{subcmd});
        return error.InvalidArgument;
    }
}

fn runAdd(allocator: std.mem.Allocator, iter: anytype) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help           Show help
        \\    --author <str>   Comment author
        \\    --json           Output as JSON
        \\<str>
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
        try stderr.writeAll("Usage: bees comment add <issue-id> <text> [--author <name>] [--json]\n");
        return;
    }

    const issue_id = res.positionals[0] orelse {
        const stderr = io.stderr();
        try stderr.writeAll("Error: issue ID is required\nUsage: bees comment add <issue-id> <text>\n");
        return error.MissingArgument;
    };

    const text = res.positionals[1] orelse {
        const stderr = io.stderr();
        try stderr.writeAll("Error: comment text is required\nUsage: bees comment add <issue-id> <text>\n");
        return error.MissingArgument;
    };

    var db = try root.openDb(allocator);
    defer db.close();

    var store = store_mod.Store.init(db);

    // Verify issue exists
    var existing = (try store.getIssue(allocator, issue_id)) orelse {
        const stderr = io.stderr();
        try stderr.print("Error: issue '{s}' not found\n", .{issue_id});
        return error.NotFound;
    };
    existing.deinit(allocator);

    const now = timestamp.now();
    try store.addComment(issue_id, res.args.author, text, &now);

    const stdout = io.stdout();
    if (res.args.json != 0) {
        var json_buf: [4096]u8 = undefined;
        var json_w = io.JsonWriter.init(stdout, &json_buf);
        var jw = json_w.stringify();
        try jw.beginObject();
        try jw.objectField("issue_id");
        try jw.write(issue_id);
        try jw.objectField("added");
        try jw.write(true);
        try jw.endObject();
        try jw.writer.writeByte('\n');
        try jw.writer.flush();
    } else {
        try stdout.print("Comment added to {s}\n", .{issue_id});
    }
}

fn runList(allocator: std.mem.Allocator, iter: anytype) !void {
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
        const stderr = io.stderr();
        try stderr.writeAll("Usage: bees comment list <issue-id> [--json]\n");
        return;
    }

    const issue_id = res.positionals[0] orelse {
        const stderr = io.stderr();
        try stderr.writeAll("Error: issue ID is required\nUsage: bees comment list <issue-id>\n");
        return error.MissingArgument;
    };

    var db = try root.openDb(allocator);
    defer db.close();

    var store = store_mod.Store.init(db);

    // Verify issue exists
    var existing = (try store.getIssue(allocator, issue_id)) orelse {
        const stderr = io.stderr();
        try stderr.print("Error: issue '{s}' not found\n", .{issue_id});
        return error.NotFound;
    };
    existing.deinit(allocator);

    const comments = try store.listComments(allocator, issue_id);
    defer {
        for (comments) |*c| c.deinit(allocator);
        allocator.free(comments);
    }

    const stdout = io.stdout();

    if (res.args.json != 0) {
        var json_buf: [4096]u8 = undefined;
        var json_w = io.JsonWriter.init(stdout, &json_buf);
        var jw = json_w.stringify();
        try jw.beginArray();
        for (comments) |*c| {
            try jw.beginObject();
            try jw.objectField("id");
            try jw.write(c.id);
            if (c.author) |a| {
                try jw.objectField("author");
                try jw.write(a);
            }
            try jw.objectField("text");
            try jw.write(c.text);
            try jw.objectField("created_at");
            try jw.write(c.created_at);
            try jw.endObject();
        }
        try jw.endArray();
        try jw.writer.writeByte('\n');
        try jw.writer.flush();
    } else {
        if (comments.len == 0) {
            try stdout.print("No comments on {s}\n", .{issue_id});
        } else {
            for (comments) |*c| {
                const author = c.author orelse "anonymous";
                try stdout.print("[{s}] {s}: {s}\n", .{ c.created_at, author, c.text });
            }
        }
    }
}
