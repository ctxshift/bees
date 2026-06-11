const std = @import("std");
const sqlite = @import("sqlite");
const store_mod = @import("../db/store.zig");
const config_mod = @import("../export/config.zig");
const jsonl = @import("../export/jsonl.zig");
const root = @import("../main.zig");

/// `bees rename-prefix <new-prefix> [--dry-run]`
///
/// Rewrites every issue id from `<old>-N` to `<new>-N`, along with the
/// dependency/label/comment rows that reference them, ID-shaped references
/// embedded in text fields (only `old-<digits>`, never bare prose containing
/// the prefix), and the stored `issue_prefix` config. `next_issue_number` is
/// left untouched so numbering continues without collisions.
pub fn run(allocator: std.mem.Allocator, iter: anytype) !void {
    const stderr = std.fs.File.stderr().deprecatedWriter();
    const stdout = std.fs.File.stdout().deprecatedWriter();

    var new_prefix: ?[]const u8 = null;
    var dry_run = false;
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try stderr.writeAll(
                \\Usage: bees rename-prefix <new-prefix> [--dry-run]
                \\
                \\Rewrite all issue ids (and references to them) to use a new
                \\prefix. --dry-run reports what would change without writing.
                \\
            );
            return;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (new_prefix == null) {
            new_prefix = arg;
        }
    }

    const new = new_prefix orelse {
        try stderr.writeAll("Error: new prefix required\nUsage: bees rename-prefix <new-prefix> [--dry-run]\n");
        return error.MissingArgument;
    };

    // Validate: non-empty, no whitespace or dashes (the dash is the id
    // separator). Keep it conservative.
    if (new.len == 0) {
        try stderr.writeAll("Error: new prefix must not be empty\n");
        return error.InvalidArgument;
    }
    for (new) |c| {
        if (std.ascii.isWhitespace(c) or c == '-') {
            try stderr.writeAll("Error: prefix must not contain whitespace or '-'\n");
            return error.InvalidArgument;
        }
    }

    var db = try root.openDb(allocator);
    defer db.close();
    var store = store_mod.Store.init(db);

    const old = (try store.getConfigAlloc(allocator, "issue_prefix")) orelse try allocator.dupe(u8, "bee");
    defer allocator.free(old);

    if (std.mem.eql(u8, old, new)) {
        try stdout.print("Prefix is already '{s}'; nothing to do.\n", .{new});
        return;
    }

    const pat = try std.fmt.allocPrint(allocator, "{s}-%", .{old});
    defer allocator.free(pat);
    const old_len: i32 = @intCast(old.len);

    // Collect issues up front so we can rewrite text references and report counts.
    const issues = try store.listIssues(allocator, .{});
    defer {
        for (issues) |*i| i.deinit(allocator);
        allocator.free(issues);
    }

    var id_hits: u32 = 0;
    var text_hits: u32 = 0;
    for (issues) |*issue| {
        if (std.mem.startsWith(u8, issue.id, old) and issue.id.len > old.len and issue.id[old.len] == '-') {
            id_hits += 1;
        }
        if (issueHasTextRef(issue, old)) text_hits += 1;
    }

    if (dry_run) {
        try stdout.print("Dry run: rename prefix '{s}' -> '{s}'\n", .{ old, new });
        try stdout.print("  issues to renumber:        {d}\n", .{id_hits});
        try stdout.print("  issues with text refs:     {d}\n", .{text_hits});
        try stdout.print("  dependency rows affected:  {d}\n", .{try countLike(&store, "dependencies", "issue_id", pat) + try countLike(&store, "dependencies", "depends_on_id", pat)});
        try stdout.print("  label rows affected:       {d}\n", .{try countLike(&store, "labels", "issue_id", pat)});
        try stdout.print("  comment rows affected:     {d}\n", .{try countLike(&store, "comments", "issue_id", pat)});
        try stdout.writeAll("No changes written.\n");
        return;
    }

    // Foreign keys must be off while we rewrite ids: the id column and the
    // dependency rows that reference it change in separate statements.
    // PRAGMA foreign_keys is a no-op inside a transaction, so set it first.
    try db.exec("PRAGMA foreign_keys=OFF", .{});
    db.exec("BEGIN", .{}) catch {};
    errdefer {
        db.exec("ROLLBACK", .{}) catch {};
        db.exec("PRAGMA foreign_keys=ON", .{}) catch {};
    }

    // 1. Text references inside issue fields. Done before the id rewrite so we
    //    match the old ids; only `old-<digits>` is replaced, never bare prose.
    for (issues) |*issue| {
        try rewriteTextField(&store, allocator, issue.id, "title", issue.title, old, new);
        if (issue.description) |v| try rewriteTextField(&store, allocator, issue.id, "description", v, old, new);
        if (issue.close_reason) |v| try rewriteTextField(&store, allocator, issue.id, "close_reason", v, old, new);
        if (issue.notes) |v| try rewriteTextField(&store, allocator, issue.id, "notes", v, old, new);
        if (issue.design) |v| try rewriteTextField(&store, allocator, issue.id, "design", v, old, new);
        if (issue.acceptance_criteria) |v| try rewriteTextField(&store, allocator, issue.id, "acceptance_criteria", v, old, new);
    }

    // 2. The id column and every table that references it.
    try renameCol(&db, "issues", "id", new, old_len, pat);
    try renameCol(&db, "dependencies", "issue_id", new, old_len, pat);
    try renameCol(&db, "dependencies", "depends_on_id", new, old_len, pat);
    try renameCol(&db, "labels", "issue_id", new, old_len, pat);
    try renameCol(&db, "comments", "issue_id", new, old_len, pat);

    // 3. Config. next_issue_number is intentionally left as-is.
    try store.setConfig("issue_prefix", new);

    try db.exec("COMMIT", .{});
    try db.exec("PRAGMA foreign_keys=ON", .{});

    // Write through to config.json and re-export the JSONL so the committed
    // artifact carries the new ids.
    if (root.findBeesDir(allocator)) |bees_path| {
        defer allocator.free(bees_path);
        if (std.fs.openDirAbsolute(bees_path, .{})) |*dir| {
            defer @constCast(dir).close();
            config_mod.write(dir.*, .{ .issue_prefix = new }) catch {};
            jsonl.exportAll(&store, allocator, dir.*) catch {};
        } else |_| {}
    } else |_| {}

    try stdout.print("Renamed prefix '{s}' -> '{s}' ({d} issues). Re-exported issues.jsonl.\n", .{ old, new, id_hits });
}

fn renameCol(db: *sqlite.Database, table: []const u8, col: []const u8, new: []const u8, old_len: i32, pat: []const u8) !void {
    // table/col are internal constants (not user input), safe to interpolate.
    var buf: [256]u8 = undefined;
    const sql = try std.fmt.bufPrint(
        &buf,
        "UPDATE {s} SET {s} = :newp || substr({s}, :oldlen + 1) WHERE {s} LIKE :pat",
        .{ table, col, col, col },
    );
    try db.exec(sql, .{ .newp = sqlite.text(new), .oldlen = old_len, .pat = sqlite.text(pat) });
}

fn rewriteTextField(store: *store_mod.Store, allocator: std.mem.Allocator, id: []const u8, col: []const u8, value: []const u8, old: []const u8, new: []const u8) !void {
    const replaced = try replaceIdRefs(allocator, value, old, new);
    defer if (replaced) |r| allocator.free(r);
    const r = replaced orelse return;

    var buf: [128]u8 = undefined;
    const sql = try std.fmt.bufPrint(&buf, "UPDATE issues SET {s} = :v WHERE id = :id", .{col});
    try store.db.exec(sql, .{ .v = sqlite.text(r), .id = sqlite.text(id) });
}

/// Returns true if `text` contains an ID-shaped reference `old-<digit...>`.
fn issueHasTextRef(issue: *const store_mod.IssueResult, old: []const u8) bool {
    const fields = [_]?[]const u8{
        issue.title, issue.description, issue.close_reason,
        issue.notes, issue.design,      issue.acceptance_criteria,
    };
    for (fields) |maybe| {
        if (maybe) |v| {
            if (containsIdRef(v, old)) return true;
        }
    }
    return false;
}

fn containsIdRef(text: []const u8, old: []const u8) bool {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, old)) |pos| {
        const after = pos + old.len;
        if (after + 1 < text.len + 1 and after < text.len and text[after] == '-' and after + 1 < text.len and std.ascii.isDigit(text[after + 1])) {
            return true;
        }
        i = pos + 1;
    }
    return false;
}

/// Replace every `old-<digits>` occurrence with `new-<digits>`. Returns an
/// allocated copy if anything changed, or null if no ID-shaped ref was found
/// (so bare prose mentioning the prefix is left untouched).
fn replaceIdRefs(allocator: std.mem.Allocator, text: []const u8, old: []const u8, new: []const u8) !?[]u8 {
    if (!containsIdRef(text, old)) return null;

    var out = std.ArrayList(u8){};
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < text.len) {
        if (std.mem.startsWith(u8, text[i..], old) and
            i + old.len < text.len and
            text[i + old.len] == '-' and
            i + old.len + 1 < text.len and
            std.ascii.isDigit(text[i + old.len + 1]))
        {
            // Matched `old-<digit>`: emit new prefix, skip old prefix, keep the rest.
            try out.appendSlice(allocator, new);
            i += old.len;
        } else {
            try out.append(allocator, text[i]);
            i += 1;
        }
    }

    return try out.toOwnedSlice(allocator);
}

fn countLike(store: *store_mod.Store, table: []const u8, col: []const u8, pat: []const u8) !i32 {
    var buf: [128]u8 = undefined;
    const sql = try std.fmt.bufPrint(&buf, "SELECT COUNT(*) AS count FROM {s} WHERE {s} LIKE :pat", .{ table, col });
    const stmt = try store.db.prepare(
        struct { pat: sqlite.Text },
        struct { count: i32 },
        sql,
    );
    defer stmt.finalize();
    stmt.bind(.{ .pat = sqlite.text(pat) }) catch return 0;
    const row = (try stmt.step()) orelse return 0;
    return row.count;
}
