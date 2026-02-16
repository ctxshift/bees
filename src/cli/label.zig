const std = @import("std");
const clap = @import("clap");
const store_mod = @import("../db/store.zig");
const timestamp = @import("../timestamp.zig");
const root = @import("../main.zig");

pub fn run(allocator: std.mem.Allocator, iter: anytype) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help   Show help
        \\<str>
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
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.writeAll("Usage:\n  bees label add <issue-id> <label>\n  bees label remove <issue-id> <label>\n");
        return;
    }

    const subcmd = res.positionals[0] orelse {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.writeAll("Error: subcommand required (add, remove)\n");
        return error.MissingArgument;
    };

    var db = try root.openDb(allocator);
    defer db.close();

    var store = store_mod.Store.init(db);
    const stdout = std.fs.File.stdout().deprecatedWriter();

    if (std.mem.eql(u8, subcmd, "add")) {
        const issue_id = res.positionals[1] orelse {
            const stderr = std.fs.File.stderr().deprecatedWriter();
            try stderr.writeAll("Error: issue-id required\n");
            return error.MissingArgument;
        };
        const label_name = res.positionals[2] orelse {
            const stderr = std.fs.File.stderr().deprecatedWriter();
            try stderr.writeAll("Error: label required\n");
            return error.MissingArgument;
        };
        const now = timestamp.now();
        try store.addLabel(issue_id, label_name, &now);
        try stdout.print("Added label '{s}' to {s}\n", .{ label_name, issue_id });
    } else if (std.mem.eql(u8, subcmd, "remove")) {
        const issue_id = res.positionals[1] orelse {
            const stderr = std.fs.File.stderr().deprecatedWriter();
            try stderr.writeAll("Error: issue-id required\n");
            return error.MissingArgument;
        };
        const label_name = res.positionals[2] orelse {
            const stderr = std.fs.File.stderr().deprecatedWriter();
            try stderr.writeAll("Error: label required\n");
            return error.MissingArgument;
        };
        try store.removeLabel(issue_id, label_name);
        try stdout.print("Removed label '{s}' from {s}\n", .{ label_name, issue_id });
    } else {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.print("Error: unknown label subcommand '{s}'\n", .{subcmd});
        return error.InvalidArgument;
    }
}
