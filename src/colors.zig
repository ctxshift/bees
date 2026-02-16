const std = @import("std");

// 24-bit ANSI color codes matching beads/bd output
pub const reset = "\x1b[0m";
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
    return ""; // task and others: default color
}

pub fn shouldUseColor() bool {
    const handle = std.fs.File.stdout();
    return handle.isTty();
}
