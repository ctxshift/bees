const std = @import("std");
const connection = @import("../db/connection.zig");
const schema = @import("../db/schema.zig");
const store_mod = @import("../db/store.zig");
const metadata_mod = @import("../export/metadata.zig");
const config_mod = @import("../export/config.zig");
const symlink = @import("../symlink.zig");

pub fn run(allocator: std.mem.Allocator) !void {
    const cwd = std.fs.cwd();

    // Check if already initialized
    cwd.access(".bees", .{}) catch {
        // Not found - create it
        try cwd.makeDir(".bees");
    };

    var bees_dir = try cwd.openDir(".bees", .{});
    defer bees_dir.close();

    // Detect project prefix from directory name
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = try std.fs.cwd().realpath(".", &cwd_buf);
    const project_name = std.fs.path.basename(cwd_path);
    const prefix = if (project_name.len > 0) project_name else "bee";

    // Write metadata.json
    try metadata_mod.write(bees_dir);

    // Write config.json
    try config_mod.write(bees_dir, .{ .issue_prefix = prefix });

    // Write .gitignore
    try writeGitignore(bees_dir);

    // Create and initialize database
    const db_path = try bees_dir.realpathAlloc(allocator, ".");
    defer allocator.free(db_path);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const full_db_path = try std.fmt.bufPrintZ(&path_buf, "{s}/bees.db", .{db_path});

    const db = try connection.open(full_db_path);
    defer db.close();

    try schema.init(db);

    // Set initial config in DB
    var store = store_mod.Store.init(db);
    try store.setConfig("issue_prefix", prefix);
    try store.setConfig("next_issue_number", "1");
    try store.setConfig("bd_version", "0.1.0");

    // Create .beads symlink
    symlink.ensureBeadsSymlinkAtPath(".") catch {};

    // Create beads.db -> bees.db symlink (for vscode-beads extension compatibility)
    bees_dir.symLink("bees.db", "beads.db", .{}) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Create empty issues.jsonl
    const jsonl_file = try bees_dir.createFile("issues.jsonl", .{ .exclusive = true });
    jsonl_file.close();

    const stdout = std.fs.File.stdout().deprecatedWriter();
    try stdout.print("Initialized bees in .bees/ (prefix: {s})\n", .{prefix});
}

fn writeGitignore(dir: std.fs.Dir) !void {
    const content =
        \\# SQLite databases
        \\*.db
        \\*.db?*
        \\*.db-journal
        \\*.db-wal
        \\*.db-shm
        \\
        \\# Daemon runtime files
        \\daemon.lock
        \\daemon.log
        \\daemon.pid
        \\bd.sock
        \\last-touched
        \\
        \\# Lock files
        \\.jsonl.lock
        \\
    ;
    const file = try dir.createFile(".gitignore", .{});
    defer file.close();
    try file.writeAll(content);
}
