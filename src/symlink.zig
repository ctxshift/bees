const std = @import("std");

pub fn ensureBeadsSymlink(bees_dir: std.fs.Dir) !void {
    const parent = bees_dir.openDir("..", .{}) catch return;
    defer parent.close();

    _ = parent.statFile(".beads") catch |err| {
        if (err == error.FileNotFound) {
            parent.symLink(".bees", ".beads", .{}) catch |sym_err| {
                if (sym_err != error.PathAlreadyExists) {
                    return sym_err;
                }
            };
        }
        return;
    };
}

pub fn ensureBeadsSymlinkAtPath(project_dir: []const u8) !void {
    var dir = try std.fs.cwd().openDir(project_dir, .{});
    defer dir.close();

    _ = dir.statFile(".beads") catch |err| {
        if (err == error.FileNotFound) {
            dir.symLink(".bees", ".beads", .{}) catch |sym_err| {
                if (sym_err != error.PathAlreadyExists) {
                    return sym_err;
                }
            };
        }
        return;
    };
}
