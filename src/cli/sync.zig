const std = @import("std");
const clap = @import("clap");
const store_mod = @import("../db/store.zig");
const jsonl = @import("../export/jsonl.zig");
const root = @import("../main.zig");

pub fn run(allocator: std.mem.Allocator, iter: anytype) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help   Show help
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
        try stderr.writeAll("Usage: bees sync\n\nExports database to issues.jsonl\n");
        return;
    }

    var db = try root.openDb(allocator);
    defer db.close();

    var store = store_mod.Store.init(db);

    const bees_dir = std.fs.cwd().openDir(".bees", .{}) catch {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.writeAll("Error: not in a bees project (no .bees/ directory)\n");
        return error.NotInitialized;
    };
    defer @constCast(&bees_dir).close();

    try jsonl.exportAll(&store, allocator, bees_dir);

    const stdout = std.fs.File.stdout().deprecatedWriter();
    try stdout.writeAll("Synced database to issues.jsonl\n");
}
