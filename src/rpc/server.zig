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
    try std.posix.listen(server, 128);

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
    const log_file = std.fs.cwd().createFile(log_path, .{}) catch {
        return error.Unexpected;
    };
    defer log_file.close();
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

    // Set receive timeout so we don't block the accept loop forever
    // if a client keeps the connection open without sending data.
    const timeout = std.posix.timeval{ .sec = 2, .usec = 0 };
    std.posix.setsockopt(conn_fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};

    const conn_file = std.fs.File{ .handle = conn_fd };
    const writer = conn_file.deprecatedWriter();

    // Read buffer for chunked reading (much faster than byte-at-a-time)
    var read_buf: [8192]u8 = undefined;
    var carry = std.ArrayList(u8){};
    defer carry.deinit(allocator);

    while (!shutdown_requested) {
        const line = readLine(conn_file, &read_buf, &carry, allocator) catch |err| {
            if (err == error.EndOfStream) return;
            log_writer.print("Read error: {}\n", .{err}) catch {};
            return;
        };
        defer allocator.free(line);

        // Trim trailing \r if present
        const trimmed = std.mem.trimRight(u8, line, "\r");
        if (trimmed.len == 0) continue;

        // Log raw request for debugging
        log_writer.print("REQ: {s}\n", .{trimmed}) catch {};

        // Parse request
        var parsed = protocol.parseRequest(allocator, trimmed) catch {
            log_writer.writeAll("REQ: parse failed\n") catch {};
            protocol.writeError(writer, "invalid JSON request") catch return;
            continue;
        };
        defer parsed.deinit();

        // Dispatch
        const result = handler.handleRequest(allocator, store, &parsed.request, state) catch |err| {
            log_writer.print("REQ: handler error: {s}\n", .{@errorName(err)}) catch {};
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
            log_writer.print("RES: error: {s}\n", .{handler.errorMessage(result)}) catch {};
            protocol.writeError(writer, handler.errorMessage(result)) catch return;
        } else {
            log_writer.print("RES: ok ({d} bytes)\n", .{result.len}) catch {};
            protocol.writeSuccess(writer, result) catch return;
        }
    }
}

/// Read a newline-delimited line from a file, using chunked reads.
/// Returns an owned slice that the caller must free.
fn readLine(file: std.fs.File, buf: *[8192]u8, carry: *std.ArrayList(u8), allocator: std.mem.Allocator) ![]const u8 {
    // Check if carry already contains a full line from a previous read
    if (std.mem.indexOf(u8, carry.items, "\n")) |nl| {
        const line = try allocator.dupe(u8, carry.items[0..nl]);
        // Shift remaining data to front
        const remaining = carry.items.len - nl - 1;
        if (remaining > 0) {
            std.mem.copyForwards(u8, carry.items[0..remaining], carry.items[nl + 1 ..]);
        }
        carry.shrinkRetainingCapacity(remaining);
        return line;
    }

    while (true) {
        const n = file.read(buf) catch |err| {
            if (carry.items.len > 0) {
                const line = try allocator.dupe(u8, carry.items);
                carry.clearRetainingCapacity();
                return line;
            }
            return err;
        };
        if (n == 0) {
            if (carry.items.len > 0) {
                const line = try allocator.dupe(u8, carry.items);
                carry.clearRetainingCapacity();
                return line;
            }
            return error.EndOfStream;
        }

        const chunk = buf[0..n];
        if (std.mem.indexOf(u8, chunk, "\n")) |nl| {
            // Found newline — combine carry + chunk[0..nl]
            try carry.appendSlice(allocator, chunk[0..nl]);
            const line = try allocator.dupe(u8, carry.items);
            // Store remainder after newline for next call
            carry.clearRetainingCapacity();
            if (nl + 1 < n) {
                try carry.appendSlice(allocator, chunk[nl + 1 .. n]);
            }
            return line;
        } else {
            // No newline yet, accumulate
            try carry.appendSlice(allocator, chunk);
            if (carry.items.len > 65536) return error.StreamTooLong;
        }
    }
}
