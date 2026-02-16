const std = @import("std");
const clap = @import("clap");
const store_mod = @import("../db/store.zig");
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
        try stderr.writeAll("Usage:\n  bees config get <key>\n  bees config set <key> <value>\n");
        return;
    }

    const subcmd = res.positionals[0] orelse {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.writeAll("Error: subcommand required (get, set)\n");
        return error.MissingArgument;
    };

    var db = try root.openDb(allocator);
    defer db.close();

    var store = store_mod.Store.init(db);
    const stdout = std.fs.File.stdout().deprecatedWriter();

    if (std.mem.eql(u8, subcmd, "get")) {
        const key = res.positionals[1] orelse {
            const stderr = std.fs.File.stderr().deprecatedWriter();
            try stderr.writeAll("Error: key required\n");
            return error.MissingArgument;
        };
        const value = try store.getConfigAlloc(allocator, key);
        if (value) |v| {
            defer allocator.free(v);
            try stdout.print("{s}\n", .{v});
        } else {
            const stderr = std.fs.File.stderr().deprecatedWriter();
            try stderr.print("Config key '{s}' not set\n", .{key});
        }
    } else if (std.mem.eql(u8, subcmd, "set")) {
        const key = res.positionals[1] orelse {
            const stderr = std.fs.File.stderr().deprecatedWriter();
            try stderr.writeAll("Error: key required\n");
            return error.MissingArgument;
        };
        const value = res.positionals[2] orelse {
            const stderr = std.fs.File.stderr().deprecatedWriter();
            try stderr.writeAll("Error: value required\n");
            return error.MissingArgument;
        };
        try store.setConfig(key, value);
        try stdout.print("{s} = {s}\n", .{ key, value });
    } else {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.print("Error: unknown config subcommand '{s}'\n", .{subcmd});
        return error.InvalidArgument;
    }
}
