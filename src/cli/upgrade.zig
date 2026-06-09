const std = @import("std");
const connection = @import("../db/connection.zig");
const schema = @import("../db/schema.zig");
const store_mod = @import("../db/store.zig");
const init_cmd = @import("init.zig");
const root = @import("../main.zig");

/// Idempotent, non-destructive migration of an existing `.bees` project to the
/// current layout. Unlike `init`, this never rebuilds the database from JSONL.
pub fn run(allocator: std.mem.Allocator) !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    const bees_path = root.findBeesDir(allocator) catch {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.writeAll("Error: not in a bees project (no .bees/ directory found)\nRun 'bees init' to initialize.\n");
        return error.NotInitialized;
    };
    defer allocator.free(bees_path);

    var bees_dir = try std.fs.openDirAbsolute(bees_path, .{});
    defer bees_dir.close();

    var changed: u32 = 0;

    // Remove the legacy root `.beads -> .bees` symlink (created by old versions
    // for the upstream vscode-beads extension). deleteFile unlinks the symlink
    // itself; it fails harmlessly if `.beads` is absent or a real directory.
    if (std.fs.path.dirname(bees_path)) |project_root| {
        var root_dir = try std.fs.openDirAbsolute(project_root, .{});
        defer root_dir.close();
        if (removeSymlink(root_dir, ".beads")) {
            try stdout.writeAll("Removed legacy .beads symlink\n");
            changed += 1;
        }
    }

    // Remove the legacy `.bees/beads.db -> bees.db` symlink.
    if (removeSymlink(bees_dir, "beads.db")) {
        try stdout.writeAll("Removed legacy .bees/beads.db symlink\n");
        changed += 1;
    }

    // Refresh .gitignore (e.g. bd.sock -> bees.sock).
    try init_cmd.writeGitignore(bees_dir);
    try stdout.writeAll("Refreshed .bees/.gitignore\n");
    changed += 1;

    // Run schema migrations against the existing database (do NOT rebuild).
    if (bees_dir.access("bees.db", .{})) |_| {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const db_path = try std.fmt.bufPrintZ(&path_buf, "{s}/bees.db", .{bees_path});

        var db = try connection.open(db_path);
        defer db.close();
        try schema.init(db);
        try stdout.writeAll("Applied schema migrations to bees.db\n");
        changed += 1;

        // Migrate the legacy bd_version config key.
        var store = store_mod.Store.init(db);
        if (try store.getConfigAlloc(allocator, "bees_version")) |v| {
            allocator.free(v);
        } else if (try store.getConfigAlloc(allocator, "bd_version")) |v| {
            defer allocator.free(v);
            try store.setConfig("bees_version", v);
            try stdout.writeAll("Migrated config key bd_version -> bees_version\n");
            changed += 1;
        }
    } else |_| {
        try stdout.writeAll("No bees.db found; run 'bees init' to rebuild it from issues.jsonl\n");
    }

    try stdout.print("Upgrade complete ({d} change(s)).\n", .{changed});
}

/// Unlink `name` in `dir` if it exists and is removable as a file/symlink.
/// Returns true if something was removed.
fn removeSymlink(dir: std.fs.Dir, name: []const u8) bool {
    dir.deleteFile(name) catch return false;
    return true;
}
