const std = @import("std");
const sqlite = @import("sqlite");

const Db = sqlite.Database;

const IssueRow = struct {
    id: sqlite.Text,
    title: sqlite.Text,
    description: ?sqlite.Text = null,
    status: sqlite.Text,
    priority: i32,
    issue_type: sqlite.Text,
    assignee: ?sqlite.Text = null,
    owner: ?sqlite.Text = null,
    created_by: ?sqlite.Text = null,
    created_at: sqlite.Text,
    updated_at: sqlite.Text,
    closed_at: ?sqlite.Text = null,
    close_reason: ?sqlite.Text = null,
    due_at: ?sqlite.Text = null,
    defer_until: ?sqlite.Text = null,
    estimated_minutes: ?i32 = null,
    external_ref: ?sqlite.Text = null,
    pinned: i32 = 0,
    is_template: i32 = 0,
    ephemeral: i32 = 0,
    metadata: ?sqlite.Text = null,
};

const CountRow = struct { count: i32 };

pub const Store = struct {
    db: Db,

    pub fn init(db: Db) Store {
        return .{ .db = db };
    }

    // --- Config ---

    pub fn setConfig(self: *Store, key: []const u8, value: []const u8) !void {
        try self.db.exec(
            "INSERT INTO config (key, value) VALUES (:key, :value) ON CONFLICT(key) DO UPDATE SET value = :value",
            .{ .key = sqlite.text(key), .value = sqlite.text(value) },
        );
    }

    pub fn getConfigAlloc(self: *Store, allocator: std.mem.Allocator, key: []const u8) !?[]const u8 {
        const stmt = try self.db.prepare(
            struct { key: sqlite.Text },
            struct { value: sqlite.Text },
            "SELECT value FROM config WHERE key = :key",
        );
        defer stmt.finalize();

        stmt.bind(.{ .key = sqlite.text(key) }) catch return null;
        const row = (try stmt.step()) orelse return null;
        return try allocator.dupe(u8, row.value.data);
    }

    // --- Issue CRUD ---

    pub fn createIssue(self: *Store, args: struct {
        id: []const u8,
        title: []const u8,
        description: ?[]const u8 = null,
        status: []const u8 = "open",
        priority: i32 = 2,
        issue_type: []const u8 = "task",
        assignee: ?[]const u8 = null,
        owner: ?[]const u8 = null,
        created_by: ?[]const u8 = null,
        created_at: []const u8,
        updated_at: []const u8,
    }) !void {
        try self.db.exec(
            "INSERT INTO issues (id, title, description, status, priority, issue_type, assignee, owner, created_by, created_at, updated_at) VALUES (:id, :title, :description, :status, :priority, :issue_type, :assignee, :owner, :created_by, :created_at, :updated_at)",
            .{
                .id = sqlite.text(args.id),
                .title = sqlite.text(args.title),
                .description = if (args.description) |d| @as(?sqlite.Text, sqlite.text(d)) else null,
                .status = sqlite.text(args.status),
                .priority = args.priority,
                .issue_type = sqlite.text(args.issue_type),
                .assignee = if (args.assignee) |a| @as(?sqlite.Text, sqlite.text(a)) else null,
                .owner = if (args.owner) |o| @as(?sqlite.Text, sqlite.text(o)) else null,
                .created_by = if (args.created_by) |c| @as(?sqlite.Text, sqlite.text(c)) else null,
                .created_at = sqlite.text(args.created_at),
                .updated_at = sqlite.text(args.updated_at),
            },
        );
    }

    pub fn getIssue(self: *Store, allocator: std.mem.Allocator, issue_id: []const u8) !?IssueResult {
        @setEvalBranchQuota(10000);
        const stmt = try self.db.prepare(
            struct { id: sqlite.Text },
            IssueRow,
            "SELECT id, title, description, status, priority, issue_type, assignee, owner, created_by, created_at, updated_at, closed_at, close_reason, due_at, defer_until, estimated_minutes, external_ref, pinned, is_template, ephemeral, metadata FROM issues WHERE id = :id",
        );
        defer stmt.finalize();

        stmt.bind(.{ .id = sqlite.text(issue_id) }) catch return null;
        const row = (try stmt.step()) orelse return null;
        return try IssueResult.fromRow(allocator, row);
    }

    pub fn listIssues(self: *Store, allocator: std.mem.Allocator, filter: ListFilter) ![]IssueResult {
        @setEvalBranchQuota(100000);
        var results = std.ArrayList(IssueResult){};
        errdefer {
            for (results.items) |*item| item.deinit(allocator);
            results.deinit(allocator);
        }

        if (filter.status != null and filter.assignee != null and filter.priority != null) {
            const stmt = try self.db.prepare(
                struct { status: sqlite.Text, assignee: sqlite.Text, priority: i32 },
                IssueRow,
                "SELECT id, title, description, status, priority, issue_type, assignee, owner, created_by, created_at, updated_at, closed_at, close_reason, due_at, defer_until, estimated_minutes, external_ref, pinned, is_template, ephemeral, metadata FROM issues WHERE status = :status AND assignee = :assignee AND priority = :priority ORDER BY priority ASC, created_at DESC",
            );
            defer stmt.finalize();
            stmt.bind(.{
                .status = sqlite.text(filter.status.?),
                .assignee = sqlite.text(filter.assignee.?),
                .priority = filter.priority.?,
            }) catch return results.toOwnedSlice(allocator);
            try self.collectRows(allocator, stmt, &results);
        } else if (filter.status != null and filter.assignee != null) {
            const stmt = try self.db.prepare(
                struct { status: sqlite.Text, assignee: sqlite.Text },
                IssueRow,
                "SELECT id, title, description, status, priority, issue_type, assignee, owner, created_by, created_at, updated_at, closed_at, close_reason, due_at, defer_until, estimated_minutes, external_ref, pinned, is_template, ephemeral, metadata FROM issues WHERE status = :status AND assignee = :assignee ORDER BY priority ASC, created_at DESC",
            );
            defer stmt.finalize();
            stmt.bind(.{
                .status = sqlite.text(filter.status.?),
                .assignee = sqlite.text(filter.assignee.?),
            }) catch return results.toOwnedSlice(allocator);
            try self.collectRows(allocator, stmt, &results);
        } else if (filter.status != null and filter.priority != null) {
            const stmt = try self.db.prepare(
                struct { status: sqlite.Text, priority: i32 },
                IssueRow,
                "SELECT id, title, description, status, priority, issue_type, assignee, owner, created_by, created_at, updated_at, closed_at, close_reason, due_at, defer_until, estimated_minutes, external_ref, pinned, is_template, ephemeral, metadata FROM issues WHERE status = :status AND priority = :priority ORDER BY priority ASC, created_at DESC",
            );
            defer stmt.finalize();
            stmt.bind(.{
                .status = sqlite.text(filter.status.?),
                .priority = filter.priority.?,
            }) catch return results.toOwnedSlice(allocator);
            try self.collectRows(allocator, stmt, &results);
        } else if (filter.assignee != null and filter.priority != null) {
            const stmt = try self.db.prepare(
                struct { assignee: sqlite.Text, priority: i32 },
                IssueRow,
                "SELECT id, title, description, status, priority, issue_type, assignee, owner, created_by, created_at, updated_at, closed_at, close_reason, due_at, defer_until, estimated_minutes, external_ref, pinned, is_template, ephemeral, metadata FROM issues WHERE assignee = :assignee AND priority = :priority ORDER BY priority ASC, created_at DESC",
            );
            defer stmt.finalize();
            stmt.bind(.{
                .assignee = sqlite.text(filter.assignee.?),
                .priority = filter.priority.?,
            }) catch return results.toOwnedSlice(allocator);
            try self.collectRows(allocator, stmt, &results);
        } else if (filter.status) |status| {
            const stmt = try self.db.prepare(
                struct { status: sqlite.Text },
                IssueRow,
                "SELECT id, title, description, status, priority, issue_type, assignee, owner, created_by, created_at, updated_at, closed_at, close_reason, due_at, defer_until, estimated_minutes, external_ref, pinned, is_template, ephemeral, metadata FROM issues WHERE status = :status ORDER BY priority ASC, created_at DESC",
            );
            defer stmt.finalize();
            stmt.bind(.{ .status = sqlite.text(status) }) catch return results.toOwnedSlice(allocator);
            try self.collectRows(allocator, stmt, &results);
        } else if (filter.assignee) |assignee| {
            const stmt = try self.db.prepare(
                struct { assignee: sqlite.Text },
                IssueRow,
                "SELECT id, title, description, status, priority, issue_type, assignee, owner, created_by, created_at, updated_at, closed_at, close_reason, due_at, defer_until, estimated_minutes, external_ref, pinned, is_template, ephemeral, metadata FROM issues WHERE assignee = :assignee ORDER BY priority ASC, created_at DESC",
            );
            defer stmt.finalize();
            stmt.bind(.{ .assignee = sqlite.text(assignee) }) catch return results.toOwnedSlice(allocator);
            try self.collectRows(allocator, stmt, &results);
        } else if (filter.priority) |priority| {
            const stmt = try self.db.prepare(
                struct { priority: i32 },
                IssueRow,
                "SELECT id, title, description, status, priority, issue_type, assignee, owner, created_by, created_at, updated_at, closed_at, close_reason, due_at, defer_until, estimated_minutes, external_ref, pinned, is_template, ephemeral, metadata FROM issues WHERE priority = :priority ORDER BY priority ASC, created_at DESC",
            );
            defer stmt.finalize();
            stmt.bind(.{ .priority = priority }) catch return results.toOwnedSlice(allocator);
            try self.collectRows(allocator, stmt, &results);
        } else {
            const stmt = try self.db.prepare(
                struct {},
                IssueRow,
                "SELECT id, title, description, status, priority, issue_type, assignee, owner, created_by, created_at, updated_at, closed_at, close_reason, due_at, defer_until, estimated_minutes, external_ref, pinned, is_template, ephemeral, metadata FROM issues ORDER BY priority ASC, created_at DESC",
            );
            defer stmt.finalize();
            try self.collectRows(allocator, stmt, &results);
        }

        return results.toOwnedSlice(allocator);
    }

    fn collectRows(self: *Store, allocator: std.mem.Allocator, stmt: anytype, results: *std.ArrayList(IssueResult)) !void {
        _ = self;
        while (true) {
            const row = (try stmt.step()) orelse break;
            try results.append(allocator, try IssueResult.fromRow(allocator, row));
        }
    }

    pub fn updateIssue(self: *Store, issue_id: []const u8, args: UpdateArgs) !void {
        if (args.title) |title| {
            try self.db.exec(
                "UPDATE issues SET title = :title, updated_at = :updated_at WHERE id = :id",
                .{ .title = sqlite.text(title), .updated_at = sqlite.text(&args.updated_at), .id = sqlite.text(issue_id) },
            );
        }
        if (args.status) |status| {
            try self.db.exec(
                "UPDATE issues SET status = :status, updated_at = :updated_at WHERE id = :id",
                .{ .status = sqlite.text(status), .updated_at = sqlite.text(&args.updated_at), .id = sqlite.text(issue_id) },
            );
        }
        if (args.priority) |priority| {
            try self.db.exec(
                "UPDATE issues SET priority = :priority, updated_at = :updated_at WHERE id = :id",
                .{ .priority = priority, .updated_at = sqlite.text(&args.updated_at), .id = sqlite.text(issue_id) },
            );
        }
        if (args.assignee) |assignee| {
            try self.db.exec(
                "UPDATE issues SET assignee = :assignee, updated_at = :updated_at WHERE id = :id",
                .{ .assignee = sqlite.text(assignee), .updated_at = sqlite.text(&args.updated_at), .id = sqlite.text(issue_id) },
            );
        }
        if (args.description) |desc| {
            try self.db.exec(
                "UPDATE issues SET description = :description, updated_at = :updated_at WHERE id = :id",
                .{ .description = sqlite.text(desc), .updated_at = sqlite.text(&args.updated_at), .id = sqlite.text(issue_id) },
            );
        }
        if (args.issue_type) |it| {
            try self.db.exec(
                "UPDATE issues SET issue_type = :issue_type, updated_at = :updated_at WHERE id = :id",
                .{ .issue_type = sqlite.text(it), .updated_at = sqlite.text(&args.updated_at), .id = sqlite.text(issue_id) },
            );
        }
        if (args.owner) |owner| {
            try self.db.exec(
                "UPDATE issues SET owner = :owner, updated_at = :updated_at WHERE id = :id",
                .{ .owner = sqlite.text(owner), .updated_at = sqlite.text(&args.updated_at), .id = sqlite.text(issue_id) },
            );
        }
    }

    pub fn closeIssue(self: *Store, issue_id: []const u8, close_reason: ?[]const u8, closed_at: []const u8) !void {
        try self.db.exec(
            "UPDATE issues SET status = :status, closed_at = :closed_at, close_reason = :close_reason, updated_at = :updated_at WHERE id = :id",
            .{
                .status = sqlite.text("closed"),
                .closed_at = sqlite.text(closed_at),
                .close_reason = if (close_reason) |r| @as(?sqlite.Text, sqlite.text(r)) else null,
                .updated_at = sqlite.text(closed_at),
                .id = sqlite.text(issue_id),
            },
        );
    }

    // --- Ready issues ---

    pub fn listReady(self: *Store, allocator: std.mem.Allocator) ![]IssueResult {
        @setEvalBranchQuota(10000);
        var results = std.ArrayList(IssueResult){};
        errdefer {
            for (results.items) |*item| item.deinit(allocator);
            results.deinit(allocator);
        }

        const stmt = try self.db.prepare(
            struct {},
            IssueRow,
            "SELECT id, title, description, status, priority, issue_type, assignee, owner, created_by, created_at, updated_at, closed_at, close_reason, due_at, defer_until, estimated_minutes, external_ref, pinned, is_template, ephemeral, metadata FROM ready_issues ORDER BY priority ASC, created_at ASC",
        );
        defer stmt.finalize();

        while (true) {
            const row = (try stmt.step()) orelse break;
            try results.append(allocator, try IssueResult.fromRow(allocator, row));
        }

        return results.toOwnedSlice(allocator);
    }

    // --- Dependencies ---

    pub fn addDep(self: *Store, issue_id: []const u8, depends_on: []const u8, dep_type: []const u8, created_at: []const u8) !void {
        try self.db.exec(
            "INSERT OR IGNORE INTO dependencies (issue_id, depends_on_id, dep_type, created_at) VALUES (:issue_id, :depends_on_id, :dep_type, :created_at)",
            .{
                .issue_id = sqlite.text(issue_id),
                .depends_on_id = sqlite.text(depends_on),
                .dep_type = sqlite.text(dep_type),
                .created_at = sqlite.text(created_at),
            },
        );
    }

    pub fn removeDep(self: *Store, issue_id: []const u8, depends_on: []const u8) !void {
        try self.db.exec(
            "DELETE FROM dependencies WHERE issue_id = :issue_id AND depends_on_id = :depends_on_id",
            .{
                .issue_id = sqlite.text(issue_id),
                .depends_on_id = sqlite.text(depends_on),
            },
        );
    }

    pub fn listDeps(self: *Store, allocator: std.mem.Allocator, issue_id: []const u8) ![]DepResult {
        var results = std.ArrayList(DepResult){};
        errdefer {
            for (results.items) |*item| item.deinit(allocator);
            results.deinit(allocator);
        }

        const stmt = try self.db.prepare(
            struct { issue_id: sqlite.Text },
            struct { depends_on_id: sqlite.Text, dep_type: sqlite.Text, created_at: sqlite.Text },
            "SELECT depends_on_id, dep_type, created_at FROM dependencies WHERE issue_id = :issue_id",
        );
        defer stmt.finalize();
        stmt.bind(.{ .issue_id = sqlite.text(issue_id) }) catch return results.toOwnedSlice(allocator);

        while (true) {
            const row = (try stmt.step()) orelse break;
            try results.append(allocator, .{
                .depends_on_id = try allocator.dupe(u8, row.depends_on_id.data),
                .dep_type = try allocator.dupe(u8, row.dep_type.data),
                .created_at = try allocator.dupe(u8, row.created_at.data),
            });
        }

        return results.toOwnedSlice(allocator);
    }

    // --- Labels ---

    pub fn addLabel(self: *Store, issue_id: []const u8, label: []const u8, created_at: []const u8) !void {
        try self.db.exec(
            "INSERT OR IGNORE INTO labels (issue_id, label, created_at) VALUES (:issue_id, :label, :created_at)",
            .{
                .issue_id = sqlite.text(issue_id),
                .label = sqlite.text(label),
                .created_at = sqlite.text(created_at),
            },
        );
    }

    pub fn removeLabel(self: *Store, issue_id: []const u8, label: []const u8) !void {
        try self.db.exec(
            "DELETE FROM labels WHERE issue_id = :issue_id AND label = :label",
            .{
                .issue_id = sqlite.text(issue_id),
                .label = sqlite.text(label),
            },
        );
    }

    pub fn listLabels(self: *Store, allocator: std.mem.Allocator, issue_id: []const u8) ![][]const u8 {
        var results = std.ArrayList([]const u8){};
        errdefer {
            for (results.items) |item| allocator.free(item);
            results.deinit(allocator);
        }

        const stmt = try self.db.prepare(
            struct { issue_id: sqlite.Text },
            struct { label: sqlite.Text },
            "SELECT label FROM labels WHERE issue_id = :issue_id ORDER BY label",
        );
        defer stmt.finalize();
        stmt.bind(.{ .issue_id = sqlite.text(issue_id) }) catch return results.toOwnedSlice(allocator);

        while (true) {
            const row = (try stmt.step()) orelse break;
            try results.append(allocator, try allocator.dupe(u8, row.label.data));
        }

        return results.toOwnedSlice(allocator);
    }

    // --- Comments ---

    pub fn addComment(self: *Store, issue_id: []const u8, author: ?[]const u8, comment_text: []const u8, created_at: []const u8) !void {
        try self.db.exec(
            "INSERT INTO comments (issue_id, author, text, created_at) VALUES (:issue_id, :author, :text, :created_at)",
            .{
                .issue_id = sqlite.text(issue_id),
                .author = if (author) |a| @as(?sqlite.Text, sqlite.text(a)) else null,
                .text = sqlite.text(comment_text),
                .created_at = sqlite.text(created_at),
            },
        );
    }

    pub fn listComments(self: *Store, allocator: std.mem.Allocator, issue_id: []const u8) ![]CommentResult {
        var results = std.ArrayList(CommentResult){};
        errdefer {
            for (results.items) |*item| item.deinit(allocator);
            results.deinit(allocator);
        }

        const stmt = try self.db.prepare(
            struct { issue_id: sqlite.Text },
            struct { id: i64, author: ?sqlite.Text = null, text: sqlite.Text, created_at: sqlite.Text },
            "SELECT id, author, text, created_at FROM comments WHERE issue_id = :issue_id ORDER BY created_at ASC",
        );
        defer stmt.finalize();
        stmt.bind(.{ .issue_id = sqlite.text(issue_id) }) catch return results.toOwnedSlice(allocator);

        while (true) {
            const row = (try stmt.step()) orelse break;
            try results.append(allocator, .{
                .id = row.id,
                .author = if (row.author) |a| try allocator.dupe(u8, a.data) else null,
                .text = try allocator.dupe(u8, row.text.data),
                .created_at = try allocator.dupe(u8, row.created_at.data),
            });
        }

        return results.toOwnedSlice(allocator);
    }

    // --- Stats ---

    pub fn countByStatus(self: *Store, status: []const u8) i32 {
        const stmt = self.db.prepare(
            struct { status: sqlite.Text },
            CountRow,
            "SELECT COUNT(*) as count FROM issues WHERE status = :status",
        ) catch return 0;
        defer stmt.finalize();
        stmt.bind(.{ .status = sqlite.text(status) }) catch return 0;
        const row = (stmt.step() catch return 0) orelse return 0;
        return row.count;
    }

    pub fn countTotal(self: *Store) i32 {
        const stmt = self.db.prepare(
            struct {},
            CountRow,
            "SELECT COUNT(*) as count FROM issues",
        ) catch return 0;
        defer stmt.finalize();
        const row = (stmt.step() catch return 0) orelse return 0;
        return row.count;
    }

    // --- Next ID ---

    pub fn nextId(self: *Store, allocator: std.mem.Allocator) !struct { id: []const u8, number: i64 } {
        const prefix = (try self.getConfigAlloc(allocator, "issue_prefix")) orelse try allocator.dupe(u8, "bee");
        defer allocator.free(prefix);
        const next_num_str = try self.getConfigAlloc(allocator, "next_issue_number") orelse try allocator.dupe(u8, "1");
        defer allocator.free(next_num_str);
        const next_num = std.fmt.parseInt(i64, next_num_str, 10) catch 1;

        var buf: [64]u8 = undefined;
        const id_slice = std.fmt.bufPrint(&buf, "{s}-{d}", .{ prefix, next_num }) catch unreachable;
        const id = try allocator.dupe(u8, id_slice);

        // Increment
        var num_buf: [20]u8 = undefined;
        const new_num_str = std.fmt.bufPrint(&num_buf, "{d}", .{next_num + 1}) catch unreachable;
        try self.setConfig("next_issue_number", new_num_str);

        return .{ .id = id, .number = next_num };
    }
};

pub const ListFilter = struct {
    status: ?[]const u8 = null,
    assignee: ?[]const u8 = null,
    priority: ?i32 = null,
};

pub const UpdateArgs = struct {
    title: ?[]const u8 = null,
    status: ?[]const u8 = null,
    priority: ?i32 = null,
    assignee: ?[]const u8 = null,
    description: ?[]const u8 = null,
    issue_type: ?[]const u8 = null,
    owner: ?[]const u8 = null,
    updated_at: [20]u8,
};

pub const IssueResult = struct {
    id: []const u8,
    title: []const u8,
    description: ?[]const u8,
    status: []const u8,
    priority: i32,
    issue_type: []const u8,
    assignee: ?[]const u8,
    owner: ?[]const u8,
    created_by: ?[]const u8,
    created_at: []const u8,
    updated_at: []const u8,
    closed_at: ?[]const u8,
    close_reason: ?[]const u8,
    due_at: ?[]const u8,
    defer_until: ?[]const u8,
    estimated_minutes: ?i32,
    external_ref: ?[]const u8,
    pinned: i32,
    is_template: i32,
    ephemeral: i32,
    metadata: ?[]const u8,

    pub fn fromRow(allocator: std.mem.Allocator, row: IssueRow) !IssueResult {
        return .{
            .id = try allocator.dupe(u8, row.id.data),
            .title = try allocator.dupe(u8, row.title.data),
            .description = if (row.description) |d| try allocator.dupe(u8, d.data) else null,
            .status = try allocator.dupe(u8, row.status.data),
            .priority = row.priority,
            .issue_type = try allocator.dupe(u8, row.issue_type.data),
            .assignee = if (row.assignee) |a| try allocator.dupe(u8, a.data) else null,
            .owner = if (row.owner) |o| try allocator.dupe(u8, o.data) else null,
            .created_by = if (row.created_by) |c| try allocator.dupe(u8, c.data) else null,
            .created_at = try allocator.dupe(u8, row.created_at.data),
            .updated_at = try allocator.dupe(u8, row.updated_at.data),
            .closed_at = if (row.closed_at) |c| try allocator.dupe(u8, c.data) else null,
            .close_reason = if (row.close_reason) |c| try allocator.dupe(u8, c.data) else null,
            .due_at = if (row.due_at) |d| try allocator.dupe(u8, d.data) else null,
            .defer_until = if (row.defer_until) |d| try allocator.dupe(u8, d.data) else null,
            .estimated_minutes = row.estimated_minutes,
            .external_ref = if (row.external_ref) |e| try allocator.dupe(u8, e.data) else null,
            .pinned = row.pinned,
            .is_template = row.is_template,
            .ephemeral = row.ephemeral,
            .metadata = if (row.metadata) |m| try allocator.dupe(u8, m.data) else null,
        };
    }

    pub fn deinit(self: *IssueResult, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.title);
        if (self.description) |d| allocator.free(d);
        allocator.free(self.status);
        allocator.free(self.issue_type);
        if (self.assignee) |a| allocator.free(a);
        if (self.owner) |o| allocator.free(o);
        if (self.created_by) |c| allocator.free(c);
        allocator.free(self.created_at);
        allocator.free(self.updated_at);
        if (self.closed_at) |c| allocator.free(c);
        if (self.close_reason) |c| allocator.free(c);
        if (self.due_at) |d| allocator.free(d);
        if (self.defer_until) |d| allocator.free(d);
        if (self.external_ref) |e| allocator.free(e);
        if (self.metadata) |m| allocator.free(m);
    }

    pub fn jsonStringify(self: *const IssueResult, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("id");
        try jw.write(self.id);
        try jw.objectField("title");
        try jw.write(self.title);
        if (self.description) |v| {
            try jw.objectField("description");
            try jw.write(v);
        }
        try jw.objectField("status");
        try jw.write(self.status);
        try jw.objectField("priority");
        try jw.write(self.priority);
        try jw.objectField("issue_type");
        try jw.write(self.issue_type);
        if (self.assignee) |v| {
            try jw.objectField("assignee");
            try jw.write(v);
        }
        if (self.owner) |v| {
            try jw.objectField("owner");
            try jw.write(v);
        }
        if (self.created_by) |v| {
            try jw.objectField("created_by");
            try jw.write(v);
        }
        try jw.objectField("created_at");
        try jw.write(self.created_at);
        try jw.objectField("updated_at");
        try jw.write(self.updated_at);
        if (self.closed_at) |v| {
            try jw.objectField("closed_at");
            try jw.write(v);
        }
        if (self.close_reason) |v| {
            try jw.objectField("close_reason");
            try jw.write(v);
        }
        if (self.due_at) |v| {
            try jw.objectField("due_at");
            try jw.write(v);
        }
        if (self.defer_until) |v| {
            try jw.objectField("defer_until");
            try jw.write(v);
        }
        if (self.estimated_minutes) |v| {
            try jw.objectField("estimated_minutes");
            try jw.write(v);
        }
        if (self.external_ref) |v| {
            try jw.objectField("external_ref");
            try jw.write(v);
        }
        if (self.pinned != 0) {
            try jw.objectField("pinned");
            try jw.write(true);
        }
        if (self.is_template != 0) {
            try jw.objectField("is_template");
            try jw.write(true);
        }
        if (self.ephemeral != 0) {
            try jw.objectField("ephemeral");
            try jw.write(true);
        }
        if (self.metadata) |v| {
            try jw.objectField("metadata");
            try jw.write(v);
        }
        try jw.endObject();
    }
};

pub const DepResult = struct {
    depends_on_id: []const u8,
    dep_type: []const u8,
    created_at: []const u8,

    pub fn deinit(self: *const DepResult, allocator: std.mem.Allocator) void {
        allocator.free(self.depends_on_id);
        allocator.free(self.dep_type);
        allocator.free(self.created_at);
    }
};

pub const CommentResult = struct {
    id: i64,
    author: ?[]const u8,
    text: []const u8,
    created_at: []const u8,

    pub fn deinit(self: *CommentResult, allocator: std.mem.Allocator) void {
        if (self.author) |a| allocator.free(a);
        allocator.free(self.text);
        allocator.free(self.created_at);
    }
};
