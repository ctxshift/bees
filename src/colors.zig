const std = @import("std");

// 24-bit ANSI color codes matching beads Ayu dark-mode palette
pub const reset = "\x1b[0m";
pub const bold = "\x1b[1m";
pub const dim = "\x1b[38;2;108;118;128m"; // muted #6c7680
pub const header = "\x1b[38;2;89;194;255m"; // accent #59c2ff

// Priority colors (P0/P1 colored, P2 subtle, P3/P4 neutral)
const p0 = "\x1b[1m\x1b[38;2;240;113;120m"; // bold red #f07178
const p1 = "\x1b[38;2;255;143;64m"; // orange #ff8f40
const p2 = "\x1b[38;2;230;180;80m"; // gold #e6b450

// Type colors (only bug and epic are colored)
const bug = "\x1b[38;2;242;109;120m"; // red #f26d78
const epic = "\x1b[38;2;210;166;255m"; // purple #d2a6ff

// Status colors
pub const status_open = ""; // default terminal color
pub const status_wip = "\x1b[38;2;255;180;84m"; // yellow #ffb454
pub const status_closed = "\x1b[38;2;128;144;160m"; // gray #8090a0
pub const status_blocked = "\x1b[38;2;242;109;120m"; // red #f26d78

// Dep/label colors
pub const label_color = "\x1b[38;2;108;118;128m"; // muted #6c7680
pub const blocked_by_color = "\x1b[38;2;242;109;120m"; // red #f26d78
pub const blocks_color = "\x1b[38;2;108;118;128m"; // muted #6c7680

pub fn priorityColor(priority: i32) []const u8 {
    return switch (priority) {
        0 => p0,
        1 => p1,
        2 => p2,
        else => "", // P3/P4: neutral
    };
}

pub fn typeColor(issue_type: []const u8) []const u8 {
    if (std.mem.eql(u8, issue_type, "bug")) return bug;
    if (std.mem.eql(u8, issue_type, "epic")) return epic;
    return ""; // task, feature, chore: neutral
}

pub const arrow = "\xe2\x86\xb3"; // ↳
pub const dot = "\xc2\xb7"; // ·
pub const priority_dot = "\xe2\x97\x8f"; // ●

pub fn statusIcon(status: []const u8) []const u8 {
    if (std.mem.eql(u8, status, "in_progress")) return "\xe2\x97\x90"; // ◐
    if (std.mem.eql(u8, status, "closed")) return "\xe2\x9c\x93"; // ✓
    if (std.mem.eql(u8, status, "deferred")) return "\xe2\x9d\x84"; // ❄
    return "\xe2\x97\x8b"; // ○
}

pub fn statusColor(status: []const u8) []const u8 {
    if (std.mem.eql(u8, status, "in_progress")) return status_wip;
    if (std.mem.eql(u8, status, "closed")) return status_closed;
    return status_open;
}

pub fn shouldUseColor() bool {
    const handle = std.fs.File.stdout();
    return handle.isTty();
}
