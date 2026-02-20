const std = @import("std");
const sqlite = @import("sqlite");
const connection = @import("db/connection.zig");
const schema = @import("db/schema.zig");
const store_mod = @import("db/store.zig");
const config_mod = @import("export/config.zig");
const init_cmd = @import("cli/init.zig");
const create_cmd = @import("cli/create.zig");
const list_cmd = @import("cli/list.zig");
const show_cmd = @import("cli/show.zig");
const update_cmd = @import("cli/update.zig");
const close_cmd = @import("cli/close.zig");
const ready_cmd = @import("cli/ready.zig");
const dep_cmd = @import("cli/dep.zig");
const label_cmd = @import("cli/label.zig");
const config_cmd = @import("cli/config_cmd.zig");
const sync_cmd = @import("cli/sync.zig");
const prime_cmd = @import("cli/prime.zig");
const comment_cmd = @import("cli/comment_cmd.zig");
const edit_cmd = @import("cli/edit.zig");
const daemon_cmd = @import("cli/daemon_cmd.zig");

pub fn openDb(allocator: std.mem.Allocator) !sqlite.Database {
    // Find .bees directory
    const bees_path = findBeesDir(allocator) catch |err| {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        stderr.writeAll("Error: not in a bees project (no .bees/ directory found)\nRun 'bees init' to initialize.\n") catch {};
        return err;
    };
    defer allocator.free(bees_path);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = std.fmt.bufPrintZ(&path_buf, "{s}/bees.db", .{bees_path}) catch {
        return error.PathTooLong;
    };

    const db = try connection.open(db_path);
    errdefer db.close();

    // Ensure schema exists
    schema.init(db) catch |err| {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        stderr.writeAll("Error: failed to initialize database schema\n") catch {};
        return err;
    };

    // Seed issue_prefix from config.json if not set in DB
    var store = store_mod.Store.init(db);
    if ((store.getConfigAlloc(allocator, "issue_prefix") catch null) == null) {
        var bees_dir = std.fs.openDirAbsolute(bees_path, .{}) catch null;
        if (bees_dir) |*dir| {
            defer dir.close();
            const config = config_mod.read(dir.*, allocator) catch config_mod.Config{};
            defer @constCast(&config).deinit(allocator);
            if (config.issue_prefix) |prefix| {
                store.setConfig("issue_prefix", prefix) catch {};
            }
        }
    }

    return db;
}

pub fn findBeesDir(allocator: std.mem.Allocator) ![]const u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    var dir_path: []const u8 = try std.fs.cwd().realpath(".", &cwd_buf);

    while (true) {
        var check_buf: [std.fs.max_path_bytes]u8 = undefined;
        const bees_check = std.fmt.bufPrint(&check_buf, "{s}/.bees", .{dir_path}) catch return error.PathTooLong;

        // Check if .bees exists at this level
        std.fs.accessAbsolute(bees_check, .{}) catch {
            // Go up one level
            const parent = std.fs.path.dirname(dir_path);
            if (parent == null or std.mem.eql(u8, parent.?, dir_path)) {
                return error.NotInitialized;
            }
            dir_path = parent.?;
            continue;
        };

        return try allocator.dupe(u8, bees_check);
    }
}

pub fn main() void {
    run() catch |err| {
        switch (err) {
            // User-facing errors that already printed a message
            error.NotFound, error.MissingArgument => std.process.exit(1),
            else => {
                const stderr = std.fs.File.stderr().deprecatedWriter();
                stderr.print("Error: {s}\n", .{@errorName(err)}) catch {};
                std.process.exit(1);
            },
        }
    };
}

fn run() !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    const allocator = gpa_state.allocator();
    defer _ = gpa_state.deinit();

    var iter = try std.process.ArgIterator.initWithAllocator(allocator);
    defer iter.deinit();

    // Skip executable name
    _ = iter.next();

    // Get subcommand
    const subcmd = iter.next() orelse {
        printUsage();
        return;
    };

    if (std.mem.eql(u8, subcmd, "init")) {
        try init_cmd.run(allocator);
    } else if (std.mem.eql(u8, subcmd, "create")) {
        try create_cmd.run(allocator, &iter);
    } else if (std.mem.eql(u8, subcmd, "list") or std.mem.eql(u8, subcmd, "ls")) {
        try list_cmd.run(allocator, &iter);
    } else if (std.mem.eql(u8, subcmd, "show")) {
        try show_cmd.run(allocator, &iter);
    } else if (std.mem.eql(u8, subcmd, "update")) {
        try update_cmd.run(allocator, &iter);
    } else if (std.mem.eql(u8, subcmd, "close")) {
        try close_cmd.run(allocator, &iter);
    } else if (std.mem.eql(u8, subcmd, "ready")) {
        try ready_cmd.run(allocator, &iter);
    } else if (std.mem.eql(u8, subcmd, "dep")) {
        try dep_cmd.run(allocator, &iter);
    } else if (std.mem.eql(u8, subcmd, "label")) {
        try label_cmd.run(allocator, &iter);
    } else if (std.mem.eql(u8, subcmd, "comment")) {
        try comment_cmd.run(allocator, &iter);
    } else if (std.mem.eql(u8, subcmd, "edit")) {
        try edit_cmd.run(allocator, &iter);
    } else if (std.mem.eql(u8, subcmd, "config")) {
        try config_cmd.run(allocator, &iter);
    } else if (std.mem.eql(u8, subcmd, "sync")) {
        try sync_cmd.run(allocator, &iter);
    } else if (std.mem.eql(u8, subcmd, "prime")) {
        try prime_cmd.run(allocator, &iter);
    } else if (std.mem.eql(u8, subcmd, "daemon")) {
        try daemon_cmd.run(allocator, &iter);
    } else if (std.mem.eql(u8, subcmd, "--help") or std.mem.eql(u8, subcmd, "-h")) {
        printUsage();
    } else {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.print("Unknown command: {s}\n\n", .{subcmd});
        printUsage();
    }
}

fn printUsage() void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    stdout.writeAll(
        \\bees - lightweight issue tracker
        \\
        \\Usage: bees <command> [options]
        \\
        \\Commands:
        \\  init          Initialize bees in current directory
        \\  create        Create a new issue
        \\  list (ls)     List issues
        \\  show          Show issue details
        \\  update        Update an issue
        \\  close         Close an issue
        \\  ready         Show ready issues (no blockers)
        \\  comment       Manage comments
        \\  edit          Edit issue fields with $EDITOR
        \\  dep           Manage dependencies
        \\  label         Manage labels
        \\  config        Get/set configuration
        \\  sync          Export database to JSONL
        \\  prime         Dump issues as AI context
        \\  daemon        Manage daemon (start/stop/status)
        \\
        \\Run 'bees <command> --help' for command-specific help.
        \\
    ) catch {};
}

test {
    _ = @import("timestamp.zig");
    _ = @import("id.zig");
    _ = @import("db/store_test.zig");
    _ = @import("rpc/mutations.zig");
    _ = @import("rpc/protocol.zig");
}
