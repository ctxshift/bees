const std = @import("std");

pub const MutationType = enum {
    create,
    update,
    delete,
    comment,

    pub fn toString(self: MutationType) []const u8 {
        return switch (self) {
            .create => "create",
            .update => "update",
            .delete => "delete",
            .comment => "comment",
        };
    }
};

pub const MutationEvent = struct {
    mutation_type: MutationType,
    issue_id: [64]u8,
    issue_id_len: u8,
    title: [128]u8,
    title_len: u8,
    timestamp_ms: i64,

    pub fn init(mutation_type: MutationType, issue_id: []const u8, title: []const u8, timestamp_ms: i64) MutationEvent {
        var ev: MutationEvent = .{
            .mutation_type = mutation_type,
            .issue_id = undefined,
            .issue_id_len = @intCast(@min(issue_id.len, 64)),
            .title = undefined,
            .title_len = @intCast(@min(title.len, 128)),
            .timestamp_ms = timestamp_ms,
        };
        @memcpy(ev.issue_id[0..ev.issue_id_len], issue_id[0..ev.issue_id_len]);
        @memcpy(ev.title[0..ev.title_len], title[0..ev.title_len]);
        return ev;
    }

    pub fn getIssueId(self: *const MutationEvent) []const u8 {
        return self.issue_id[0..self.issue_id_len];
    }

    pub fn getTitle(self: *const MutationEvent) []const u8 {
        return self.title[0..self.title_len];
    }
};

pub const MutationBuffer = struct {
    buf: [capacity]MutationEvent = undefined,
    head: usize = 0,
    count: usize = 0,

    const capacity = 100;

    pub fn record(self: *MutationBuffer, event: MutationEvent) void {
        const idx = (self.head + self.count) % capacity;
        self.buf[idx] = event;
        if (self.count < capacity) {
            self.count += 1;
        } else {
            self.head = (self.head + 1) % capacity;
        }
    }

    pub fn sinceCount(self: *const MutationBuffer, timestamp_ms: i64) usize {
        var start: usize = 0;
        while (start < self.count) {
            const idx = (self.head + start) % capacity;
            if (self.buf[idx].timestamp_ms >= timestamp_ms) break;
            start += 1;
        }
        return self.count - start;
    }

    pub const Iterator = struct {
        buffer: *const MutationBuffer,
        pos: usize,
        end: usize,

        pub fn next(self: *Iterator) ?*const MutationEvent {
            if (self.pos >= self.end) return null;
            const idx = (self.buffer.head + self.pos) % capacity;
            self.pos += 1;
            return &self.buffer.buf[idx];
        }
    };

    pub fn sinceIter(self: *const MutationBuffer, timestamp_ms: i64) Iterator {
        var start: usize = 0;
        while (start < self.count) {
            const idx = (self.head + start) % capacity;
            if (self.buf[idx].timestamp_ms >= timestamp_ms) break;
            start += 1;
        }
        return .{
            .buffer = self,
            .pos = start,
            .end = self.count,
        };
    }
};

test "MutationBuffer basic" {
    var mb = MutationBuffer{};
    mb.record(MutationEvent.init(.create, "bee-1", "First issue", 1000));
    mb.record(MutationEvent.init(.update, "bee-2", "Second issue", 2000));
    mb.record(MutationEvent.init(.comment, "bee-1", "First issue", 3000));

    try std.testing.expectEqual(@as(usize, 3), mb.count);

    var iter = mb.sinceIter(0);
    const e1 = iter.next().?;
    try std.testing.expectEqualStrings("bee-1", e1.getIssueId());
    try std.testing.expectEqual(MutationType.create, e1.mutation_type);

    const e2 = iter.next().?;
    try std.testing.expectEqualStrings("bee-2", e2.getIssueId());

    const e3 = iter.next().?;
    try std.testing.expectEqual(@as(i64, 3000), e3.timestamp_ms);

    try std.testing.expect(iter.next() == null);
}

test "MutationBuffer since filter" {
    var mb = MutationBuffer{};
    mb.record(MutationEvent.init(.create, "bee-1", "", 1000));
    mb.record(MutationEvent.init(.update, "bee-2", "", 2000));
    mb.record(MutationEvent.init(.comment, "bee-1", "", 3000));

    var iter = mb.sinceIter(2000);
    const e1 = iter.next().?;
    try std.testing.expectEqual(@as(i64, 2000), e1.timestamp_ms);
    const e2 = iter.next().?;
    try std.testing.expectEqual(@as(i64, 3000), e2.timestamp_ms);
    try std.testing.expect(iter.next() == null);
}

test "MutationBuffer wrapping" {
    var mb = MutationBuffer{};
    // Fill beyond capacity
    for (0..105) |i| {
        mb.record(MutationEvent.init(.update, "bee-1", "", @intCast(i)));
    }
    try std.testing.expectEqual(@as(usize, 100), mb.count);

    // Oldest should be timestamp 5
    var iter = mb.sinceIter(0);
    const first = iter.next().?;
    try std.testing.expectEqual(@as(i64, 5), first.timestamp_ms);
}
