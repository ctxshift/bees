const std = @import("std");
const sqlite = @import("sqlite");
const connection = @import("../db/connection.zig");
const schema = @import("../db/schema.zig");
const store_mod = @import("../db/store.zig");
const protocol = @import("protocol.zig");
const handler = @import("handler.zig");

var shutdown_requested: bool = false;

fn sigHandler(_: c_int) callconv(.c) void {
    shutdown_requested = true;
}

pub fn run(allocator: std.mem.Allocator, bees_dir_path: []const u8) !void {
    // Open DB
    var db_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = std.fmt.bufPrintZ(&db_path_buf, "{s}/bees.db", .{bees_dir_path}) catch
        return error.PathTooLong;

    var db = try connection.open(db_path);
    defer db.close();
    try schema.init(db);

    var store = store_mod.Store.init(db);

    // Open bees dir handle for exports
    var bees_dir = try std.fs.cwd().openDir(bees_dir_path, .{});
    defer bees_dir.close();

    // Write PID file
    var pid_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const pid_path = std.fmt.bufPrint(&pid_path_buf, "{s}/daemon.pid", .{bees_dir_path}) catch
        return error.PathTooLong;
    {
        const pid_file = try std.fs.cwd().createFile(pid_path, .{});
        defer pid_file.close();
        const pid = std.os.linux.getpid();
        var pid_buf: [20]u8 = undefined;
        const pid_str = std.fmt.bufPrint(&pid_buf, "{d}", .{pid}) catch unreachable;
        try pid_file.writeAll(pid_str);
    }
    defer std.fs.cwd().deleteFile(pid_path) catch {};

    // Socket path
    var sock_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const sock_path = std.fmt.bufPrint(&sock_path_buf, "{s}/bd.sock", .{bees_dir_path}) catch
        return error.PathTooLong;

    // Remove old socket if exists
    std.fs.cwd().deleteFile(sock_path) catch {};

    // Bind Unix socket
    const sock_path_z = std.fmt.bufPrintZ(&sock_path_buf, "{s}/bd.sock", .{bees_dir_path}) catch
        return error.PathTooLong;
    var addr = std.net.Address.initUnix(sock_path_z) catch return error.SocketPathTooLong;
    const server = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK, 0);
    defer std.posix.close(server);
    try std.posix.bind(server, &addr.any, addr.getOsSockLen());
    try std.posix.listen(server, 5);

    defer std.fs.cwd().deleteFile(sock_path) catch {};

    // Install signal handlers
    const sa = std.posix.Sigaction{
        .handler = .{ .handler = sigHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.TERM, &sa, null);
    std.posix.sigaction(std.posix.SIG.INT, &sa, null);

    // Server state
    var state = handler.ServerState{
        .start_time_ms = std.time.milliTimestamp(),
        .bees_dir_path = bees_dir_path,
        .bees_dir = bees_dir,
    };

    // Open log file for daemon output
    var log_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const log_path = std.fmt.bufPrint(&log_path_buf, "{s}/daemon.log", .{bees_dir_path}) catch
        return error.PathTooLong;
    const log_file = std.fs.cwd().createFile(log_path, .{ .truncate = false }) catch {
        return error.Unexpected;
    };
    defer log_file.close();
    log_file.seekFromEnd(0) catch {};
    const log_writer = log_file.deprecatedWriter();
    log_writer.print("bees daemon started (PID: {d})\n", .{std.os.linux.getpid()}) catch {};
    log_writer.print("Listening on {s}\n", .{sock_path}) catch {};

    // Accept loop using poll to allow checking shutdown flag
    var poll_fds = [_]std.posix.pollfd{.{
        .fd = server,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};

    while (!shutdown_requested) {
        // Poll with 500ms timeout so we check shutdown_requested regularly
        const poll_result = std.posix.poll(&poll_fds, 500) catch |err| {
            if (shutdown_requested) break;
            log_writer.print("Poll error: {}\n", .{err}) catch {};
            continue;
        };

        if (poll_result == 0) continue; // timeout, re-check shutdown
        if (shutdown_requested) break;

        const conn = std.posix.accept(server, null, null, std.posix.SOCK.CLOEXEC) catch |err| {
            if (err == error.WouldBlock) continue;
            if (err == error.ConnectionAborted or err == error.SocketNotConnected) continue;
            log_writer.print("Accept error: {}\n", .{err}) catch {};
            continue;
        };

        handleConnection(allocator, conn, &store, &state, log_writer);
    }

    log_writer.writeAll("bees daemon shutting down\n") catch {};
}

fn handleConnection(
    allocator: std.mem.Allocator,
    conn_fd: std.posix.socket_t,
    store: *store_mod.Store,
    state: *handler.ServerState,
    log_writer: anytype,
) void {
    defer std.posix.close(conn_fd);

    const conn_file = std.fs.File{ .handle = conn_fd };
    const writer = conn_file.deprecatedWriter();

    // Line buffer for reading from connection
    var line_buf = std.ArrayList(u8){};
    defer line_buf.deinit(allocator);

    while (!shutdown_requested) {
        // Read one line by reading bytes until we hit '\n'
        line_buf.clearRetainingCapacity();
        const line = readLineFromFile(conn_file, allocator, &line_buf) catch |err| {
            if (err == error.EndOfStream) return;
            log_writer.print("Read error: {}\n", .{err}) catch {};
            return;
        };

        // Trim trailing \r if present
        const trimmed = std.mem.trimRight(u8, line, "\r");
        if (trimmed.len == 0) continue;

        // Parse request
        var parsed = protocol.parseRequest(allocator, trimmed) catch {
            protocol.writeError(writer, "invalid JSON request") catch return;
            continue;
        };
        defer parsed.deinit();

        // Dispatch
        const result = handler.handleRequest(allocator, store, &parsed.request, state) catch |err| {
            var err_buf: [256]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "internal error: {s}", .{@errorName(err)}) catch "internal error";
            protocol.writeError(writer, err_msg) catch return;
            continue;
        };
        defer allocator.free(result);

        // Check for shutdown
        if (handler.isShutdown(result)) {
            protocol.writeSuccess(writer, result) catch {};
            shutdown_requested = true;
            return;
        }

        // Check if result is an error
        if (handler.isError(result)) {
            protocol.writeError(writer, handler.errorMessage(result)) catch return;
        } else {
            protocol.writeSuccess(writer, result) catch return;
        }
    }
}

fn readLineFromFile(file: std.fs.File, allocator: std.mem.Allocator, buf: *std.ArrayList(u8)) ![]const u8 {
    var byte: [1]u8 = undefined;
    while (true) {
        const n = file.read(&byte) catch |err| {
            if (buf.items.len > 0) return buf.items;
            return err;
        };
        if (n == 0) {
            if (buf.items.len > 0) return buf.items;
            return error.EndOfStream;
        }
        if (byte[0] == '\n') {
            return buf.items;
        }
        if (buf.items.len >= 65536) return error.StreamTooLong;
        try buf.append(allocator, byte[0]);
    }
}
