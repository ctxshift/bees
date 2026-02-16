const std = @import("std");
const clap = @import("clap");
const server = @import("../rpc/server.zig");
const root = @import("../main.zig");

pub fn run(allocator: std.mem.Allocator, iter: anytype) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help        Show help
        \\    --foreground   Run daemon in foreground (used internally)
        \\    --start        Start the daemon (alias for 'start' subcommand)
        \\    --stop         Stop the daemon (alias for 'stop' subcommand)
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
        try stderr.writeAll("Usage:\n  bees daemon start   Start the daemon\n  bees daemon stop    Stop the daemon\n  bees daemon status  Check daemon status\n");
        return;
    }

    // --foreground mode: the positional arg is the bees_dir path
    if (res.args.foreground != 0) {
        const bees_dir_path = res.positionals[0] orelse {
            const stderr = std.fs.File.stderr().deprecatedWriter();
            try stderr.writeAll("Error: --foreground requires bees directory path\n");
            return error.MissingArgument;
        };
        try server.run(allocator, bees_dir_path);
        return;
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();

    // Support --start/--stop flags (used by vscode-beads extension: `bd daemon --start`)
    if (res.args.start != 0) {
        try daemonStart(allocator, stdout);
        return;
    }
    if (res.args.stop != 0) {
        try daemonStop(stdout);
        return;
    }

    const subcmd = res.positionals[0] orelse {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.writeAll("Error: subcommand required (start, stop, status)\n");
        return error.MissingArgument;
    };

    if (std.mem.eql(u8, subcmd, "start")) {
        try daemonStart(allocator, stdout);
    } else if (std.mem.eql(u8, subcmd, "stop")) {
        try daemonStop(stdout);
    } else if (std.mem.eql(u8, subcmd, "status")) {
        try daemonStatus(stdout);
    } else {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.print("Error: unknown daemon subcommand '{s}'\n", .{subcmd});
        return error.InvalidArgument;
    }
}

fn daemonStart(allocator: std.mem.Allocator, stdout: anytype) !void {
    // Find .bees directory
    const bees_path = root.findBeesDir(allocator) catch {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.writeAll("Error: not in a bees project (no .bees/ directory found)\nRun 'bees init' to initialize.\n");
        return error.NotInitialized;
    };
    defer allocator.free(bees_path);

    // Check if already running
    if (isDaemonRunning(bees_path)) {
        try stdout.writeAll("Daemon is already running\n");
        return;
    }

    // Get own executable path
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = std.fs.selfExePath(&exe_buf) catch {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.writeAll("Error: could not determine executable path\n");
        return error.Unexpected;
    };

    // Spawn: bees daemon --foreground <bees_dir_path>
    // The foreground process will open its own log file internally
    const argv = [_][]const u8{
        exe_path,
        "daemon",
        "--foreground",
        bees_path,
    };

    var child = std.process.Child.init(&argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.pgid = 0; // Create new process group (detach)

    child.spawn() catch {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.writeAll("Error: failed to spawn daemon process\n");
        return error.Unexpected;
    };

    // Wait for socket to appear (up to 3 seconds)
    var sock_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const sock_path = std.fmt.bufPrint(&sock_path_buf, "{s}/bd.sock", .{bees_path}) catch
        return error.PathTooLong;

    var waited: u32 = 0;
    while (waited < 30) : (waited += 1) {
        std.Thread.sleep(100 * std.time.ns_per_ms);
        std.fs.cwd().access(sock_path, .{}) catch continue;
        // Socket appeared
        try stdout.print("Daemon started (PID: {d})\n", .{child.id});
        return;
    }

    try stdout.writeAll("Daemon process spawned but socket not yet available\n");
    try stdout.print("PID: {d} — check .bees/daemon.log for details\n", .{child.id});
}

fn daemonStop(stdout: anytype) !void {
    var bees_dir = std.fs.cwd().openDir(".bees", .{}) catch {
        try stdout.writeAll("No .bees directory found\n");
        return;
    };
    defer bees_dir.close();

    const file = bees_dir.openFile("daemon.pid", .{}) catch {
        try stdout.writeAll("No daemon running (no PID file)\n");
        return;
    };
    defer file.close();

    var buf: [20]u8 = undefined;
    const len = file.readAll(&buf) catch {
        try stdout.writeAll("Could not read PID file\n");
        return;
    };
    const pid_str = std.mem.trimRight(u8, buf[0..len], "\n\r ");
    const pid = std.fmt.parseInt(i32, pid_str, 10) catch {
        try stdout.writeAll("Invalid PID in daemon.pid\n");
        return;
    };

    // Send SIGTERM
    if (isProcessAlive(pid)) {
        std.posix.kill(pid, std.posix.SIG.TERM) catch {};
        try stdout.print("Sent SIGTERM to daemon (PID: {d})\n", .{pid});
        // Wait briefly for cleanup
        var waited: u32 = 0;
        while (waited < 20) : (waited += 1) {
            std.Thread.sleep(100 * std.time.ns_per_ms);
            bees_dir.access("bd.sock", .{}) catch {
                try stdout.writeAll("Daemon stopped\n");
                return;
            };
        }
        try stdout.writeAll("Daemon may still be shutting down\n");
    } else {
        try stdout.print("Process {d} not found (may have already exited)\n", .{pid});
        // Clean up stale files
        bees_dir.deleteFile("daemon.pid") catch {};
        bees_dir.deleteFile("bd.sock") catch {};
    }
}

fn daemonStatus(stdout: anytype) !void {
    var bees_dir = std.fs.cwd().openDir(".bees", .{}) catch {
        try stdout.writeAll("Not initialized\n");
        return;
    };
    defer bees_dir.close();

    // Check socket
    bees_dir.access("bd.sock", .{}) catch {
        try stdout.writeAll("Daemon: not running\n");
        return;
    };

    // Check PID
    const file = bees_dir.openFile("daemon.pid", .{}) catch {
        try stdout.writeAll("Daemon: socket exists but no PID file (stale?)\n");
        return;
    };
    defer file.close();

    var buf: [20]u8 = undefined;
    const len = file.readAll(&buf) catch {
        try stdout.writeAll("Daemon: could not read PID file\n");
        return;
    };
    const pid_str = std.mem.trimRight(u8, buf[0..len], "\n\r ");
    const pid = std.fmt.parseInt(i32, pid_str, 10) catch {
        try stdout.writeAll("Daemon: invalid PID file\n");
        return;
    };

    // Check if process is alive (kill -0)
    if (isProcessAlive(pid)) {
        try stdout.print("Daemon: running (PID: {d})\n", .{pid});
    } else {
        try stdout.print("Daemon: not running (stale PID: {d})\n", .{pid});
    }
}

fn isDaemonRunning(bees_path: []const u8) bool {
    // Check socket + PID alive
    var sock_buf: [std.fs.max_path_bytes]u8 = undefined;
    const sock_path = std.fmt.bufPrint(&sock_buf, "{s}/bd.sock", .{bees_path}) catch return false;
    std.fs.cwd().access(sock_path, .{}) catch return false;

    var pid_buf: [std.fs.max_path_bytes]u8 = undefined;
    const pid_path = std.fmt.bufPrint(&pid_buf, "{s}/daemon.pid", .{bees_path}) catch return false;
    const file = std.fs.cwd().openFile(pid_path, .{}) catch return false;
    defer file.close();

    var buf: [20]u8 = undefined;
    const len = file.readAll(&buf) catch return false;
    const pid_str = std.mem.trimRight(u8, buf[0..len], "\n\r ");
    const pid = std.fmt.parseInt(i32, pid_str, 10) catch return false;

    return isProcessAlive(pid);
}

fn isProcessAlive(pid: i32) bool {
    // Send signal 0 to check if process exists
    std.posix.kill(pid, 0) catch return false;
    return true;
}
