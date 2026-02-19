const std = @import("std");
const clap = @import("clap");
const store_mod = @import("../db/store.zig");
const timestamp = @import("../timestamp.zig");
const io = @import("../io.zig");
const root = @import("../main.zig");

pub fn run(allocator: std.mem.Allocator, iter: anytype) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help         Show help
        \\-t, --type <str>   Dependency type (blocks, related, parent-child)
        \\    --json         Output as JSON
        \\<str>
        \\<str>
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
        try stderr.writeAll("Usage:\n  bees dep add <issue-id> <depends-on-id> [-t blocks|related|parent-child]\n  bees dep remove <issue-id> <depends-on-id>\n  bees dep list <issue-id> [--json]\n");
        return;
    }

    const subcmd = res.positionals[0] orelse {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.writeAll("Error: subcommand required (add, remove, list)\n");
        return error.MissingArgument;
    };

    var db = try root.openDb(allocator);
    defer db.close();

    var store = store_mod.Store.init(db);
    const stdout = std.fs.File.stdout().deprecatedWriter();

    if (std.mem.eql(u8, subcmd, "add")) {
        const issue_id = res.positionals[1] orelse {
            const stderr = std.fs.File.stderr().deprecatedWriter();
            try stderr.writeAll("Error: issue-id required\n");
            return error.MissingArgument;
        };
        const depends_on = res.positionals[2] orelse {
            const stderr = std.fs.File.stderr().deprecatedWriter();
            try stderr.writeAll("Error: depends-on-id required\n");
            return error.MissingArgument;
        };
        const dep_type = res.args.type orelse "blocks";
        const now = timestamp.now();
        try store.addDep(issue_id, depends_on, dep_type, &now);
        try stdout.print("Added dependency: {s} depends on {s} ({s})\n", .{ issue_id, depends_on, dep_type });
    } else if (std.mem.eql(u8, subcmd, "remove")) {
        const issue_id = res.positionals[1] orelse {
            const stderr = std.fs.File.stderr().deprecatedWriter();
            try stderr.writeAll("Error: issue-id required\n");
            return error.MissingArgument;
        };
        const depends_on = res.positionals[2] orelse {
            const stderr = std.fs.File.stderr().deprecatedWriter();
            try stderr.writeAll("Error: depends-on-id required\n");
            return error.MissingArgument;
        };
        try store.removeDep(issue_id, depends_on);
        try stdout.print("Removed dependency: {s} -> {s}\n", .{ issue_id, depends_on });
    } else if (std.mem.eql(u8, subcmd, "list")) {
        const issue_id = res.positionals[1] orelse {
            const stderr = std.fs.File.stderr().deprecatedWriter();
            try stderr.writeAll("Error: issue-id required\n");
            return error.MissingArgument;
        };

        const deps = try store.listDeps(allocator, issue_id);
        defer {
            for (deps) |*d| d.deinit(allocator);
            allocator.free(deps);
        }

        const dependents = try store.listDependents(allocator, issue_id);
        defer {
            for (dependents) |*d| d.deinit(allocator);
            allocator.free(dependents);
        }

        if (res.args.json != 0) {
            var json_buf: [4096]u8 = undefined;
            var json_w = io.JsonWriter.init(stdout, &json_buf);
            var jw = json_w.stringify();
            try jw.beginObject();
            try jw.objectField("depends_on");
            try jw.beginArray();
            for (deps) |dep| {
                try jw.beginObject();
                try jw.objectField("id");
                try jw.write(dep.depends_on_id);
                try jw.objectField("type");
                try jw.write(dep.dep_type);
                try jw.endObject();
            }
            try jw.endArray();
            try jw.objectField("dependents");
            try jw.beginArray();
            for (dependents) |dep| {
                try jw.beginObject();
                try jw.objectField("id");
                try jw.write(dep.issue_id);
                try jw.objectField("type");
                try jw.write(dep.dep_type);
                try jw.endObject();
            }
            try jw.endArray();
            try jw.endObject();
            try jw.writer.writeByte('\n');
            try jw.writer.flush();
        } else {
            if (deps.len == 0 and dependents.len == 0) {
                try stdout.print("No dependencies for {s}\n", .{issue_id});
            } else {
                if (deps.len > 0) {
                    try stdout.writeAll("Depends on:\n");
                    for (deps) |dep| {
                        try stdout.print("  {s} ({s})\n", .{ dep.depends_on_id, dep.dep_type });
                    }
                }
                if (dependents.len > 0) {
                    try stdout.writeAll("Dependents:\n");
                    for (dependents) |dep| {
                        try stdout.print("  {s} ({s})\n", .{ dep.issue_id, dep.dep_type });
                    }
                }
            }
        }
    } else {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.print("Error: unknown dep subcommand '{s}'\n", .{subcmd});
        return error.InvalidArgument;
    }
}
