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

        for (issues) |issue| {
            const issue_labels = store.listLabels(allocator, issue.id) catch &.{};
            defer {
                for (issue_labels) |l| allocator.free(l);
                allocator.free(issue_labels);
            }

            // Ready issues have no blockers, but may block others
            const blocks_list = store.listBlocks(allocator, issue.id) catch &.{};
            defer {
                for (blocks_list) |b| allocator.free(b);
                allocator.free(blocks_list);
            }

            try writeReadyLine(stdout, issue, issue_labels, blocks_list, use_color);
        }

        try stdout.print("\n{d} ready issue(s)\n", .{issues.len});
    }
}

fn writeReadyLine(
    stdout: anytype,
    issue: store_mod.IssueResult,
    issue_labels: []const []const u8,
    blocks: []const []const u8,
    use_color: bool,
) !void {
    const priority_str: []const u8 = switch (issue.priority) {
        0 => "P0",
        1 => "P1",
        2 => "P2",
        3 => "P3",
        4 => "P4",
        else => "P?",
    };

    const status_icon = colors.statusIcon(issue.status);

    if (use_color) {
        const scolor = colors.statusColor(issue.status);
        const pcolor = colors.priorityColor(issue.priority);
        const tcolor = colors.typeColor(issue.issue_type);

        // Status icon
        try stdout.print("{s}{s}{s} ", .{ scolor, status_icon, colors.reset });
        // Issue ID
        try stdout.print("{s}{s}{s} ", .{ colors.dim, issue.id, colors.reset });
        // Priority
        try stdout.print("[{s}{s} {s}{s}] ", .{ pcolor, colors.priority_dot, priority_str, colors.reset });
        // Type
        try stdout.print("[{s}{s}{s}]", .{ tcolor, issue.issue_type, colors.reset });
        // Labels
        if (issue_labels.len > 0) {
            try stdout.print(" [{s}", .{colors.label_color});
            for (issue_labels, 0..) |label, i| {
                if (i > 0) try stdout.writeAll(" ");
                try stdout.writeAll(label);
            }
            try stdout.print("{s}]", .{colors.reset});
        }
        // Title
        try stdout.print(" - {s}", .{issue.title});
        // Blocks info (ready issues are never blocked, but may block others)
        if (blocks.len > 0) {
            try stdout.print(" {s}(blocks: ", .{colors.blocks_color});
            for (blocks, 0..) |id, i| {
                if (i > 0) try stdout.writeAll(", ");
                try stdout.writeAll(id);
            }
            try stdout.print("){s}", .{colors.reset});
        }
    } else {
        try stdout.print("{s} ", .{status_icon});
        try stdout.print("{s} ", .{issue.id});
        try stdout.print("[{s} {s}] ", .{ colors.priority_dot, priority_str });
        try stdout.print("[{s}]", .{issue.issue_type});
        if (issue_labels.len > 0) {
            try stdout.writeAll(" [");
            for (issue_labels, 0..) |label, i| {
                if (i > 0) try stdout.writeAll(" ");
                try stdout.writeAll(label);
            }
            try stdout.writeAll("]");
        }
        try stdout.print(" - {s}", .{issue.title});
        if (blocks.len > 0) {
            try stdout.writeAll(" (blocks: ");
            for (blocks, 0..) |id, i| {
                if (i > 0) try stdout.writeAll(", ");
                try stdout.writeAll(id);
            }
            try stdout.writeAll(")");
        }
    }

    try stdout.writeAll("\n");
}
