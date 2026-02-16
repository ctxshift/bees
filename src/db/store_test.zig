const std = @import("std");
const testing = std.testing;
const connection = @import("connection.zig");
const schema = @import("schema.zig");
const store_mod = @import("store.zig");

const Store = store_mod.Store;

fn setupTestDb() !struct { db: @import("sqlite").Database, store: Store } {
    const db = try connection.openMemory();
    try schema.init(db);
    var store = Store.init(db);
    try store.setConfig("issue_prefix", "test");
    try store.setConfig("next_issue_number", "1");
    return .{ .db = db, .store = store };
}

fn createTestIssue(store: *Store, id: []const u8, title: []const u8) !void {
    try store.createIssue(.{
        .id = id,
        .title = title,
        .created_at = "2026-01-01T00:00:00Z",
        .updated_at = "2026-01-01T00:00:00Z",
    });
}

// --- Config tests ---

test "config: set and get" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    try ctx.store.setConfig("foo", "bar");
    const val = try ctx.store.getConfigAlloc(testing.allocator, "foo");
    defer if (val) |v| testing.allocator.free(v);
    try testing.expectEqualStrings("bar", val.?);
}

test "config: get missing key returns null" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    const val = try ctx.store.getConfigAlloc(testing.allocator, "nonexistent");
    try testing.expect(val == null);
}

test "config: set overwrites existing" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    try ctx.store.setConfig("key", "value1");
    try ctx.store.setConfig("key", "value2");
    const val = try ctx.store.getConfigAlloc(testing.allocator, "key");
    defer if (val) |v| testing.allocator.free(v);
    try testing.expectEqualStrings("value2", val.?);
}

test "config: getConfigAlloc" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    try ctx.store.setConfig("key", "allocated_value");
    const val = try ctx.store.getConfigAlloc(testing.allocator, "key");
    defer if (val) |v| testing.allocator.free(v);
    try testing.expectEqualStrings("allocated_value", val.?);
}

// --- Issue CRUD tests ---

test "issue: create and get" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    try ctx.store.createIssue(.{
        .id = "test-1",
        .title = "Test issue",
        .description = "A description",
        .priority = 1,
        .issue_type = "bug",
        .assignee = "alice",
        .owner = "bob",
        .created_at = "2026-01-01T00:00:00Z",
        .updated_at = "2026-01-01T00:00:00Z",
    });

    var issue = (try ctx.store.getIssue(testing.allocator, "test-1")).?;
    defer issue.deinit(testing.allocator);

    try testing.expectEqualStrings("test-1", issue.id);
    try testing.expectEqualStrings("Test issue", issue.title);
    try testing.expectEqualStrings("A description", issue.description.?);
    try testing.expectEqualStrings("open", issue.status);
    try testing.expectEqual(@as(i32, 1), issue.priority);
    try testing.expectEqualStrings("bug", issue.issue_type);
    try testing.expectEqualStrings("alice", issue.assignee.?);
    try testing.expectEqualStrings("bob", issue.owner.?);
}

test "issue: get nonexistent returns null" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    const issue = try ctx.store.getIssue(testing.allocator, "nope-1");
    try testing.expect(issue == null);
}

test "issue: create with defaults" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    try ctx.store.createIssue(.{
        .id = "test-1",
        .title = "Minimal issue",
        .created_at = "2026-01-01T00:00:00Z",
        .updated_at = "2026-01-01T00:00:00Z",
    });

    var issue = (try ctx.store.getIssue(testing.allocator, "test-1")).?;
    defer issue.deinit(testing.allocator);

    try testing.expectEqualStrings("open", issue.status);
    try testing.expectEqual(@as(i32, 2), issue.priority);
    try testing.expectEqualStrings("task", issue.issue_type);
    try testing.expect(issue.description == null);
    try testing.expect(issue.assignee == null);
    try testing.expect(issue.owner == null);
}

// --- List / Filter tests ---

test "list: all issues" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    try createTestIssue(&ctx.store, "test-1", "First");
    try createTestIssue(&ctx.store, "test-2", "Second");
    try createTestIssue(&ctx.store, "test-3", "Third");

    const issues = try ctx.store.listIssues(testing.allocator, .{});
    defer {
        for (issues) |*issue| issue.deinit(testing.allocator);
        testing.allocator.free(issues);
    }

    try testing.expectEqual(@as(usize, 3), issues.len);
}

test "list: filter by status" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    try createTestIssue(&ctx.store, "test-1", "Open one");
    try createTestIssue(&ctx.store, "test-2", "To close");
    try ctx.store.closeIssue("test-2", null, "2026-01-02T00:00:00Z");

    const open = try ctx.store.listIssues(testing.allocator, .{ .status = "open" });
    defer {
        for (open) |*issue| issue.deinit(testing.allocator);
        testing.allocator.free(open);
    }
    try testing.expectEqual(@as(usize, 1), open.len);
    try testing.expectEqualStrings("test-1", open[0].id);

    const closed = try ctx.store.listIssues(testing.allocator, .{ .status = "closed" });
    defer {
        for (closed) |*issue| issue.deinit(testing.allocator);
        testing.allocator.free(closed);
    }
    try testing.expectEqual(@as(usize, 1), closed.len);
    try testing.expectEqualStrings("test-2", closed[0].id);
}

test "list: filter by priority" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    try ctx.store.createIssue(.{
        .id = "test-1",
        .title = "Critical",
        .priority = 1,
        .created_at = "2026-01-01T00:00:00Z",
        .updated_at = "2026-01-01T00:00:00Z",
    });
    try ctx.store.createIssue(.{
        .id = "test-2",
        .title = "Low",
        .priority = 4,
        .created_at = "2026-01-01T00:00:00Z",
        .updated_at = "2026-01-01T00:00:00Z",
    });

    const p1 = try ctx.store.listIssues(testing.allocator, .{ .priority = 1 });
    defer {
        for (p1) |*issue| issue.deinit(testing.allocator);
        testing.allocator.free(p1);
    }
    try testing.expectEqual(@as(usize, 1), p1.len);
    try testing.expectEqualStrings("Critical", p1[0].title);
}

test "list: filter by assignee" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    try ctx.store.createIssue(.{
        .id = "test-1",
        .title = "Alice's task",
        .assignee = "alice",
        .created_at = "2026-01-01T00:00:00Z",
        .updated_at = "2026-01-01T00:00:00Z",
    });
    try ctx.store.createIssue(.{
        .id = "test-2",
        .title = "Bob's task",
        .assignee = "bob",
        .created_at = "2026-01-01T00:00:00Z",
        .updated_at = "2026-01-01T00:00:00Z",
    });

    const alice = try ctx.store.listIssues(testing.allocator, .{ .assignee = "alice" });
    defer {
        for (alice) |*issue| issue.deinit(testing.allocator);
        testing.allocator.free(alice);
    }
    try testing.expectEqual(@as(usize, 1), alice.len);
    try testing.expectEqualStrings("Alice's task", alice[0].title);
}

test "list: combined filters" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    try ctx.store.createIssue(.{
        .id = "test-1",
        .title = "Match",
        .assignee = "alice",
        .priority = 1,
        .created_at = "2026-01-01T00:00:00Z",
        .updated_at = "2026-01-01T00:00:00Z",
    });
    try ctx.store.createIssue(.{
        .id = "test-2",
        .title = "Wrong priority",
        .assignee = "alice",
        .priority = 3,
        .created_at = "2026-01-01T00:00:00Z",
        .updated_at = "2026-01-01T00:00:00Z",
    });

    const results = try ctx.store.listIssues(testing.allocator, .{
        .assignee = "alice",
        .priority = 1,
    });
    defer {
        for (results) |*issue| issue.deinit(testing.allocator);
        testing.allocator.free(results);
    }
    try testing.expectEqual(@as(usize, 1), results.len);
    try testing.expectEqualStrings("Match", results[0].title);
}

// --- Update tests ---

test "update: title" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    try createTestIssue(&ctx.store, "test-1", "Old title");

    var now: [20]u8 = undefined;
    _ = std.fmt.bufPrint(&now, "2026-01-02T00:00:00Z", .{}) catch unreachable;
    try ctx.store.updateIssue("test-1", .{
        .title = "New title",
        .updated_at = now,
    });

    var issue = (try ctx.store.getIssue(testing.allocator, "test-1")).?;
    defer issue.deinit(testing.allocator);
    try testing.expectEqualStrings("New title", issue.title);
}

test "update: status" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    try createTestIssue(&ctx.store, "test-1", "Task");

    var now: [20]u8 = undefined;
    _ = std.fmt.bufPrint(&now, "2026-01-02T00:00:00Z", .{}) catch unreachable;
    try ctx.store.updateIssue("test-1", .{
        .status = "in_progress",
        .updated_at = now,
    });

    var issue = (try ctx.store.getIssue(testing.allocator, "test-1")).?;
    defer issue.deinit(testing.allocator);
    try testing.expectEqualStrings("in_progress", issue.status);
}

test "update: priority" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    try createTestIssue(&ctx.store, "test-1", "Task");

    var now: [20]u8 = undefined;
    _ = std.fmt.bufPrint(&now, "2026-01-02T00:00:00Z", .{}) catch unreachable;
    try ctx.store.updateIssue("test-1", .{
        .priority = 1,
        .updated_at = now,
    });

    var issue = (try ctx.store.getIssue(testing.allocator, "test-1")).?;
    defer issue.deinit(testing.allocator);
    try testing.expectEqual(@as(i32, 1), issue.priority);
}

// --- Close tests ---

test "close: basic close" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    try createTestIssue(&ctx.store, "test-1", "To close");
    try ctx.store.closeIssue("test-1", null, "2026-01-02T00:00:00Z");

    var issue = (try ctx.store.getIssue(testing.allocator, "test-1")).?;
    defer issue.deinit(testing.allocator);
    try testing.expectEqualStrings("closed", issue.status);
    try testing.expectEqualStrings("2026-01-02T00:00:00Z", issue.closed_at.?);
    try testing.expect(issue.close_reason == null);
}

test "close: with reason" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    try createTestIssue(&ctx.store, "test-1", "To close");
    try ctx.store.closeIssue("test-1", "Duplicate of test-2", "2026-01-02T00:00:00Z");

    var issue = (try ctx.store.getIssue(testing.allocator, "test-1")).?;
    defer issue.deinit(testing.allocator);
    try testing.expectEqualStrings("closed", issue.status);
    try testing.expectEqualStrings("Duplicate of test-2", issue.close_reason.?);
}

// --- Dependency tests ---

test "dep: add and list" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    try createTestIssue(&ctx.store, "test-1", "Blocker");
    try createTestIssue(&ctx.store, "test-2", "Blocked");
    try ctx.store.addDep("test-2", "test-1", "blocks", "2026-01-01T00:00:00Z");

    const deps = try ctx.store.listDeps(testing.allocator, "test-2");
    defer {
        for (deps) |*d| d.deinit(testing.allocator);
        testing.allocator.free(deps);
    }

    try testing.expectEqual(@as(usize, 1), deps.len);
    try testing.expectEqualStrings("test-1", deps[0].depends_on_id);
    try testing.expectEqualStrings("blocks", deps[0].dep_type);
}

test "dep: remove" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    try createTestIssue(&ctx.store, "test-1", "Blocker");
    try createTestIssue(&ctx.store, "test-2", "Blocked");
    try ctx.store.addDep("test-2", "test-1", "blocks", "2026-01-01T00:00:00Z");
    try ctx.store.removeDep("test-2", "test-1");

    const deps = try ctx.store.listDeps(testing.allocator, "test-2");
    defer testing.allocator.free(deps);

    try testing.expectEqual(@as(usize, 0), deps.len);
}

test "dep: multiple dependencies" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    try createTestIssue(&ctx.store, "test-1", "Dep A");
    try createTestIssue(&ctx.store, "test-2", "Dep B");
    try createTestIssue(&ctx.store, "test-3", "Main");
    try ctx.store.addDep("test-3", "test-1", "blocks", "2026-01-01T00:00:00Z");
    try ctx.store.addDep("test-3", "test-2", "related", "2026-01-01T00:00:00Z");

    const deps = try ctx.store.listDeps(testing.allocator, "test-3");
    defer {
        for (deps) |*d| d.deinit(testing.allocator);
        testing.allocator.free(deps);
    }

    try testing.expectEqual(@as(usize, 2), deps.len);
}

test "dep: duplicate add is ignored" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    try createTestIssue(&ctx.store, "test-1", "A");
    try createTestIssue(&ctx.store, "test-2", "B");
    try ctx.store.addDep("test-2", "test-1", "blocks", "2026-01-01T00:00:00Z");
    try ctx.store.addDep("test-2", "test-1", "blocks", "2026-01-01T00:00:00Z");

    const deps = try ctx.store.listDeps(testing.allocator, "test-2");
    defer {
        for (deps) |*d| d.deinit(testing.allocator);
        testing.allocator.free(deps);
    }

    try testing.expectEqual(@as(usize, 1), deps.len);
}

// --- Label tests ---

test "label: add and list" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    try createTestIssue(&ctx.store, "test-1", "Issue");
    try ctx.store.addLabel("test-1", "bug", "2026-01-01T00:00:00Z");
    try ctx.store.addLabel("test-1", "urgent", "2026-01-01T00:00:00Z");

    const labels = try ctx.store.listLabels(testing.allocator, "test-1");
    defer {
        for (labels) |l| testing.allocator.free(l);
        testing.allocator.free(labels);
    }

    try testing.expectEqual(@as(usize, 2), labels.len);
    // Labels are ordered alphabetically
    try testing.expectEqualStrings("bug", labels[0]);
    try testing.expectEqualStrings("urgent", labels[1]);
}

test "label: remove" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    try createTestIssue(&ctx.store, "test-1", "Issue");
    try ctx.store.addLabel("test-1", "bug", "2026-01-01T00:00:00Z");
    try ctx.store.addLabel("test-1", "urgent", "2026-01-01T00:00:00Z");
    try ctx.store.removeLabel("test-1", "bug");

    const labels = try ctx.store.listLabels(testing.allocator, "test-1");
    defer {
        for (labels) |l| testing.allocator.free(l);
        testing.allocator.free(labels);
    }

    try testing.expectEqual(@as(usize, 1), labels.len);
    try testing.expectEqualStrings("urgent", labels[0]);
}

test "label: duplicate add is ignored" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    try createTestIssue(&ctx.store, "test-1", "Issue");
    try ctx.store.addLabel("test-1", "bug", "2026-01-01T00:00:00Z");
    try ctx.store.addLabel("test-1", "bug", "2026-01-01T00:00:00Z");

    const labels = try ctx.store.listLabels(testing.allocator, "test-1");
    defer {
        for (labels) |l| testing.allocator.free(l);
        testing.allocator.free(labels);
    }

    try testing.expectEqual(@as(usize, 1), labels.len);
}

test "label: no labels returns empty" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    try createTestIssue(&ctx.store, "test-1", "Issue");

    const labels = try ctx.store.listLabels(testing.allocator, "test-1");
    defer testing.allocator.free(labels);

    try testing.expectEqual(@as(usize, 0), labels.len);
}

// --- Comment tests ---

test "comment: add and list" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    try createTestIssue(&ctx.store, "test-1", "Issue");
    try ctx.store.addComment("test-1", "alice", "First comment", "2026-01-01T00:00:00Z");
    try ctx.store.addComment("test-1", "bob", "Second comment", "2026-01-01T01:00:00Z");

    const comments = try ctx.store.listComments(testing.allocator, "test-1");
    defer {
        for (comments) |*c| c.deinit(testing.allocator);
        testing.allocator.free(comments);
    }

    try testing.expectEqual(@as(usize, 2), comments.len);
    try testing.expectEqualStrings("alice", comments[0].author.?);
    try testing.expectEqualStrings("First comment", comments[0].text);
    try testing.expectEqualStrings("bob", comments[1].author.?);
    try testing.expectEqualStrings("Second comment", comments[1].text);
}

test "comment: anonymous author" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    try createTestIssue(&ctx.store, "test-1", "Issue");
    try ctx.store.addComment("test-1", null, "Anonymous comment", "2026-01-01T00:00:00Z");

    const comments = try ctx.store.listComments(testing.allocator, "test-1");
    defer {
        for (comments) |*c| c.deinit(testing.allocator);
        testing.allocator.free(comments);
    }

    try testing.expectEqual(@as(usize, 1), comments.len);
    try testing.expect(comments[0].author == null);
}

// --- Ready issues tests ---

test "ready: all open issues are ready by default" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    try createTestIssue(&ctx.store, "test-1", "Task A");
    try createTestIssue(&ctx.store, "test-2", "Task B");

    const ready = try ctx.store.listReady(testing.allocator);
    defer {
        for (ready) |*issue| issue.deinit(testing.allocator);
        testing.allocator.free(ready);
    }

    try testing.expectEqual(@as(usize, 2), ready.len);
}

test "ready: blocked issue is not ready" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    try createTestIssue(&ctx.store, "test-1", "Blocker");
    try createTestIssue(&ctx.store, "test-2", "Blocked");
    try ctx.store.addDep("test-2", "test-1", "blocks", "2026-01-01T00:00:00Z");

    const ready = try ctx.store.listReady(testing.allocator);
    defer {
        for (ready) |*issue| issue.deinit(testing.allocator);
        testing.allocator.free(ready);
    }

    try testing.expectEqual(@as(usize, 1), ready.len);
    try testing.expectEqualStrings("test-1", ready[0].id);
}

test "ready: closing blocker unblocks dependent" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    try createTestIssue(&ctx.store, "test-1", "Blocker");
    try createTestIssue(&ctx.store, "test-2", "Blocked");
    try ctx.store.addDep("test-2", "test-1", "blocks", "2026-01-01T00:00:00Z");

    // Close the blocker
    try ctx.store.closeIssue("test-1", null, "2026-01-02T00:00:00Z");

    const ready = try ctx.store.listReady(testing.allocator);
    defer {
        for (ready) |*issue| issue.deinit(testing.allocator);
        testing.allocator.free(ready);
    }

    // test-2 should now be ready (blocker is closed)
    try testing.expectEqual(@as(usize, 1), ready.len);
    try testing.expectEqualStrings("test-2", ready[0].id);
}

test "ready: closed issues are not ready" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    try createTestIssue(&ctx.store, "test-1", "Closed one");
    try ctx.store.closeIssue("test-1", null, "2026-01-02T00:00:00Z");

    const ready = try ctx.store.listReady(testing.allocator);
    defer testing.allocator.free(ready);

    try testing.expectEqual(@as(usize, 0), ready.len);
}

test "ready: related deps do not block" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    try createTestIssue(&ctx.store, "test-1", "Related");
    try createTestIssue(&ctx.store, "test-2", "Main");
    try ctx.store.addDep("test-2", "test-1", "related", "2026-01-01T00:00:00Z");

    const ready = try ctx.store.listReady(testing.allocator);
    defer {
        for (ready) |*issue| issue.deinit(testing.allocator);
        testing.allocator.free(ready);
    }

    // Both should be ready - "related" deps don't block
    try testing.expectEqual(@as(usize, 2), ready.len);
}

// --- Stats tests ---

test "stats: count by status" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    try createTestIssue(&ctx.store, "test-1", "Open");
    try createTestIssue(&ctx.store, "test-2", "Also open");
    try createTestIssue(&ctx.store, "test-3", "To close");
    try ctx.store.closeIssue("test-3", null, "2026-01-02T00:00:00Z");

    try testing.expectEqual(@as(i32, 2), ctx.store.countByStatus("open"));
    try testing.expectEqual(@as(i32, 1), ctx.store.countByStatus("closed"));
    try testing.expectEqual(@as(i32, 0), ctx.store.countByStatus("in_progress"));
}

test "stats: count total" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    try createTestIssue(&ctx.store, "test-1", "One");
    try createTestIssue(&ctx.store, "test-2", "Two");

    try testing.expectEqual(@as(i32, 2), ctx.store.countTotal());
}

// --- Next ID tests ---

test "nextId: sequential generation" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    const id1 = try ctx.store.nextId(testing.allocator);
    defer testing.allocator.free(id1.id);
    try testing.expectEqualStrings("test-1", id1.id);
    try testing.expectEqual(@as(i64, 1), id1.number);

    const id2 = try ctx.store.nextId(testing.allocator);
    defer testing.allocator.free(id2.id);
    try testing.expectEqualStrings("test-2", id2.id);
    try testing.expectEqual(@as(i64, 2), id2.number);

    const id3 = try ctx.store.nextId(testing.allocator);
    defer testing.allocator.free(id3.id);
    try testing.expectEqualStrings("test-3", id3.id);
    try testing.expectEqual(@as(i64, 3), id3.number);
}

test "nextId: uses configured prefix" {
    var ctx = try setupTestDb();
    defer ctx.db.close();

    try ctx.store.setConfig("issue_prefix", "myproj");

    const id = try ctx.store.nextId(testing.allocator);
    defer testing.allocator.free(id.id);
    try testing.expectEqualStrings("myproj-1", id.id);
}

// --- Schema tests ---

test "schema: init is idempotent" {
    const db = try connection.openMemory();
    defer db.close();

    // Init twice should not error
    try schema.init(db);
    try schema.init(db);
}
