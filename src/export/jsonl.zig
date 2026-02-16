const std = @import("std");
const store_mod = @import("../db/store.zig");
const io = @import("../io.zig");

const Store = store_mod.Store;
const IssueResult = store_mod.IssueResult;

pub fn exportAll(store: *Store, allocator: std.mem.Allocator, dir: std.fs.Dir) !void {
    // Get all issues (no filter)
    const issues = try store.listIssues(allocator, .{});
    defer {
        for (issues) |*issue| issue.deinit(allocator);
        allocator.free(issues);
    }

    // Write to tmp file first, then atomic rename
    const tmp_name = "issues.jsonl.tmp";
    const final_name = "issues.jsonl";

    const file = try dir.createFile(tmp_name, .{});
    errdefer {
        file.close();
        dir.deleteFile(tmp_name) catch {};
    }

    const writer = file.deprecatedWriter();

    for (issues) |*issue| {
        // Get labels and deps for this issue
        const labels = store.listLabels(allocator, issue.id) catch &[_][]const u8{};
        defer {
            for (labels) |l| allocator.free(l);
            allocator.free(labels);
        }

        const deps = store.listDeps(allocator, issue.id) catch &[_]store_mod.DepResult{};
        defer {
            for (deps) |*d| d.deinit(allocator);
            allocator.free(deps);
        }

        // Write hydrated JSON line
        var json_buf: [8192]u8 = undefined;
        var json_w = io.JsonWriter.init(writer, &json_buf);
        var jw = json_w.stringify();
        try writeHydratedIssue(&jw, issue, labels, deps);
        try jw.writer.writeByte('\n');
        try jw.writer.flush();
    }

    file.close();

    // Atomic rename
    try dir.rename(tmp_name, final_name);
}

fn writeHydratedIssue(jw: *std.json.Stringify, issue: *const IssueResult, labels: []const []const u8, deps: []const store_mod.DepResult) !void {
    try jw.beginObject();

    try jw.objectField("id");
    try jw.write(issue.id);
    try jw.objectField("title");
    try jw.write(issue.title);
    if (issue.description) |v| {
        try jw.objectField("description");
        try jw.write(v);
    }
    try jw.objectField("status");
    try jw.write(issue.status);
    try jw.objectField("priority");
    try jw.write(issue.priority);
    try jw.objectField("issue_type");
    try jw.write(issue.issue_type);
    if (issue.assignee) |v| {
        try jw.objectField("assignee");
        try jw.write(v);
    }
    if (issue.owner) |v| {
        try jw.objectField("owner");
        try jw.write(v);
    }
    if (issue.created_by) |v| {
        try jw.objectField("created_by");
        try jw.write(v);
    }
    try jw.objectField("created_at");
    try jw.write(issue.created_at);
    try jw.objectField("updated_at");
    try jw.write(issue.updated_at);
    if (issue.closed_at) |v| {
        try jw.objectField("closed_at");
        try jw.write(v);
    }
    if (issue.close_reason) |v| {
        try jw.objectField("close_reason");
        try jw.write(v);
    }
    if (issue.due_at) |v| {
        try jw.objectField("due_at");
        try jw.write(v);
    }
    if (issue.defer_until) |v| {
        try jw.objectField("defer_until");
        try jw.write(v);
    }
    if (issue.estimated_minutes) |v| {
        try jw.objectField("estimated_minutes");
        try jw.write(v);
    }
    if (issue.external_ref) |v| {
        try jw.objectField("external_ref");
        try jw.write(v);
    }

    // Embed labels as array
    if (labels.len > 0) {
        try jw.objectField("labels");
        try jw.beginArray();
        for (labels) |label| {
            try jw.write(label);
        }
        try jw.endArray();
    }

    // Embed dependencies as array of objects
    if (deps.len > 0) {
        try jw.objectField("dependencies");
        try jw.beginArray();
        for (deps) |dep| {
            try jw.beginObject();
            try jw.objectField("issue_id");
            try jw.write(issue.id);
            try jw.objectField("depends_on_id");
            try jw.write(dep.depends_on_id);
            try jw.objectField("type");
            try jw.write(dep.dep_type);
            try jw.objectField("created_at");
            try jw.write(dep.created_at);
            try jw.endObject();
        }
        try jw.endArray();
    }

    try jw.endObject();
}
