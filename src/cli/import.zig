const std = @import("std");
const connection = @import("../db/connection.zig");
const schema = @import("../db/schema.zig");
const store_mod = @import("../db/store.zig");
const config_mod = @import("../export/config.zig");
const jsonl_import = @import("../export/jsonl_import.zig");
const root = @import("../main.zig");

/// `bees import` — rebuild the database from issues.jsonl.
///
/// The committed JSONL is the source of truth; the db is gitignored. This drops
/// the existing db and rehydrates from issues.jsonl, so a corrupted or stale db
/// can be regenerated without `bees init` (which also touches config). Unlike
/// the implicit hydrate in `openDb`, import failures (duplicate ids, malformed
/// lines) are surfaced and abort with a non-zero exit.
pub fn run(allocator: std.mem.Allocator, iter: anytype) !void {
    const stderr = std.fs.File.stderr().deprecatedWriter();

    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try stderr.writeAll(
                \\Usage: bees import
                \\
                \\Rebuild the database from issues.jsonl (drops and re-creates
                \\.bees/bees.db). Use after pulling a new issues.jsonl.
                \\
            );
            return;
        }
    }

    const bees_path = root.findBeesDir(allocator) catch {
        try stderr.writeAll("Error: not in a bees project (no .bees/ directory found)\n");
        return error.NotInitialized;
    };
    defer allocator.free(bees_path);

    var bees_dir = std.fs.openDirAbsolute(bees_path, .{}) catch {
        try stderr.writeAll("Error: cannot open .bees/ directory\n");
        return error.NotInitialized;
    };
    defer bees_dir.close();

    // Drop the db so we rebuild cleanly from issues.jsonl.
    for ([_][]const u8{ "bees.db", "bees.db-wal", "bees.db-shm" }) |name| {
        bees_dir.deleteFile(name) catch |err| {
            if (err != error.FileNotFound) return err;
        };
    }

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = std.fmt.bufPrintZ(&path_buf, "{s}/bees.db", .{bees_path}) catch return error.PathTooLong;

    const db = try connection.open(db_path);
    defer db.close();
    try schema.init(db);

    var store = store_mod.Store.init(db);

    // Seed the prefix from config.json so the rebuilt db carries it.
    const config = config_mod.read(bees_dir, allocator) catch config_mod.Config{};
    defer @constCast(&config).deinit(allocator);
    if (config.issue_prefix) |prefix| {
        store.setConfig("issue_prefix", prefix) catch {};
    }
    store.setConfig("bees_version", root.version) catch {};

    // Propagate import errors (duplicate id, malformed JSON) instead of
    // leaving a half-built db and reporting success.
    const imported = try jsonl_import.importAll(&store, allocator, bees_dir);

    const stdout = std.fs.File.stdout().deprecatedWriter();
    try stdout.print("Imported {d} issues from issues.jsonl.\n", .{imported});
}
