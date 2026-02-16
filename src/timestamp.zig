const std = @import("std");

pub fn now() [20]u8 {
    const ts = std.time.timestamp();
    return formatUnix(ts);
}

pub fn formatUnix(unix: i64) [20]u8 {
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(unix) };
    const ed = es.getEpochDay();
    const yd = ed.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();

    var buf: [20]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        yd.year,
        md.month.numeric(),
        @as(u32, md.day_index) + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    }) catch unreachable;
    return buf;
}

test "formatUnix" {
    const result = formatUnix(0);
    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", &result);
}

test "formatUnix specific date" {
    // 2024-01-15T09:50:00Z = 1705312200
    const result = formatUnix(1705312200);
    try std.testing.expectEqualStrings("2024-01-15T09:50:00Z", &result);
}
