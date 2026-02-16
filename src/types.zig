const std = @import("std");
const sqlite = @import("sqlite");

pub const Status = enum {
    open,
    in_progress,
    closed,
    deferred,

    pub fn toString(self: Status) []const u8 {
        return switch (self) {
            .open => "open",
            .in_progress => "in_progress",
            .closed => "closed",
            .deferred => "deferred",
        };
    }

    pub fn fromString(s: []const u8) ?Status {
        const map = std.StaticStringMap(Status).initComptime(.{
            .{ "open", .open },
            .{ "in_progress", .in_progress },
            .{ "closed", .closed },
            .{ "deferred", .deferred },
        });
        return map.get(s);
    }

    pub fn toText(self: Status) sqlite.Text {
        return sqlite.text(self.toString());
    }
};

pub const IssueType = enum {
    task,
    bug,
    feature,
    epic,
    story,

    pub fn toString(self: IssueType) []const u8 {
        return switch (self) {
            .task => "task",
            .bug => "bug",
            .feature => "feature",
            .epic => "epic",
            .story => "story",
        };
    }

    pub fn fromString(s: []const u8) ?IssueType {
        const map = std.StaticStringMap(IssueType).initComptime(.{
            .{ "task", .task },
            .{ "bug", .bug },
            .{ "feature", .feature },
            .{ "epic", .epic },
            .{ "story", .story },
        });
        return map.get(s);
    }

    pub fn toText(self: IssueType) sqlite.Text {
        return sqlite.text(self.toString());
    }
};

pub const DepType = enum {
    blocks,
    related,
    parent_child,

    pub fn toString(self: DepType) []const u8 {
        return switch (self) {
            .blocks => "blocks",
            .related => "related",
            .parent_child => "parent-child",
        };
    }

    pub fn fromString(s: []const u8) ?DepType {
        const map = std.StaticStringMap(DepType).initComptime(.{
            .{ "blocks", .blocks },
            .{ "related", .related },
            .{ "parent-child", .parent_child },
        });
        return map.get(s);
    }

    pub fn toText(self: DepType) sqlite.Text {
        return sqlite.text(self.toString());
    }
};

pub const Issue = struct {
    id: []const u8,
    title: []const u8,
    description: ?[]const u8 = null,
    status: []const u8,
    priority: i32,
    issue_type: []const u8,
    assignee: ?[]const u8 = null,
    owner: ?[]const u8 = null,
    created_by: ?[]const u8 = null,
    created_at: []const u8,
    updated_at: []const u8,
    closed_at: ?[]const u8 = null,
    close_reason: ?[]const u8 = null,
    due_at: ?[]const u8 = null,
    defer_until: ?[]const u8 = null,
    estimated_minutes: ?i32 = null,
    external_ref: ?[]const u8 = null,
    pinned: i32 = 0,
    is_template: i32 = 0,
    ephemeral: i32 = 0,
    metadata: ?[]const u8 = null,

    pub fn jsonStringify(self: *const Issue, jw: anytype) !void {
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

pub const Dependency = struct {
    issue_id: []const u8,
    depends_on_id: []const u8,
    dep_type: []const u8,
    created_at: []const u8,
    created_by: ?[]const u8 = null,
};

pub const Label = struct {
    issue_id: []const u8,
    label: []const u8,
    created_at: []const u8,
};

pub const Comment = struct {
    id: i64,
    issue_id: []const u8,
    author: ?[]const u8,
    text: []const u8,
    created_at: []const u8,
};
