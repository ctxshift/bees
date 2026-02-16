const std = @import("std");
const clap = @import("clap");

pub fn run(allocator: std.mem.Allocator, iter: anytype) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help   Show help
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

    const subcmd = res.positionals[0] orelse {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.writeAll("Error: subcommand required (start, stop, status)\n");
        return error.MissingArgument;
    };

    const stdout = std.fs.File.stdout().deprecatedWriter();

    if (std.mem.eql(u8, subcmd, "start")) {
        // Phase 3: daemon implementation
        try stdout.writeAll("Daemon start not yet implemented (Phase 3)\n");
    } else if (std.mem.eql(u8, subcmd, "stop")) {
        // Try to read PID file and kill
        const pid_data = std.fs.cwd().openDir(".bees", .{}) catch {
            try stdout.writeAll("No .bees directory found\n");
            return;
        };
        defer @constCast(&pid_data).close();

        const file = pid_data.openFile("daemon.pid", .{}) catch {
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
        try stdout.print("Daemon PID: {s} (stop not yet implemented)\n", .{pid_str});
    } else if (std.mem.eql(u8, subcmd, "status")) {
        const bees_dir = std.fs.cwd().openDir(".bees", .{}) catch {
            try stdout.writeAll("Not initialized\n");
            return;
        };
        defer @constCast(&bees_dir).close();

        bees_dir.access("bd.sock", .{}) catch {
            try stdout.writeAll("Daemon: not running\n");
            return;
        };
        try stdout.writeAll("Daemon: socket exists (may be running)\n");
    } else {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.print("Error: unknown daemon subcommand '{s}'\n", .{subcmd});
        return error.InvalidArgument;
    }
}
