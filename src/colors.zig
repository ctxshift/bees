const std = @import("std");

// 24-bit ANSI color codes matching beads/bd output
pub const reset = "\x1b[0m";
pub const bold = "\x1b[1m";
pub const dim = "\x1b[38;2;140;140;140m"; // gray/dim
pub const header = "\x1b[38;2;89;194;255m"; // light blue

// Priority colors
const p1 = "\x1b[38;2;255;143;64m"; // orange
const p2 = "\x1b[38;2;230;179;80m"; // amber
const p3 = "\x1b[38;2;89;194;255m"; // blue
const p4 = "\x1b[38;2;140;140;140m"; // gray

// Type colors
const bug = "\x1b[38;2;242;109;120m"; // red/pink
const epic = "\x1b[38;2;187;134;252m"; // purple
const chore = "\x1b[38;2;140;140;140m"; // gray
const feature = "\x1b[38;2;120;220;120m"; // green

// Status colors
pub const status_open = ""; // default terminal color
pub const status_wip = "\x1b[38;2;89;194;255m"; // blue
pub const status_closed = "\x1b[38;2;140;140;140m"; // gray

// Dep/label colors
pub const label_color = "\x1b[38;2;170;170;170m"; // light gray
pub const blocked_by_color = "\x1b[38;2;242;109;120m"; // red/pink
pub const blocks_color = "\x1b[38;2;170;170;170m"; // light gray

pub fn priorityColor(priority: i32) []const u8 {
    return switch (priority) {
        1 => p1,
        2 => p2,
        3 => p3,
        4 => p4,
        else => p2,
    };
}

pub fn typeColor(issue_type: []const u8) []const u8 {
    if (std.mem.eql(u8, issue_type, "bug")) return bug;
    if (std.mem.eql(u8, issue_type, "epic")) return epic;
    if (std.mem.eql(u8, issue_type, "chore")) return chore;
    if (std.mem.eql(u8, issue_type, "feature")) return feature;
    return ""; // task and others: default color
}

pub fn statusIcon(status: []const u8) []const u8 {
    if (std.mem.eql(u8, status, "in_progress")) return "\xe2\x97\x90"; // ◐
    if (std.mem.eql(u8, status, "closed")) return "\xe2\x97\x8f"; // ●
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
