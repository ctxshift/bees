const std = @import("std");
const clap = @import("clap");

pub fn run(allocator: std.mem.Allocator, iter: anytype) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help   Show help
        \\
    );

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        try diag.reportToFile(.stderr(), err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.writeAll("Usage: bees prime\n\nDumps workflow context for AI agents.\n");
        return;
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();

    try stdout.writeAll(
        \\# Bees Workflow Context
        \\
        \\> **Context Recovery**: Run `bees prime` after compaction, clear, or new session
        \\
        \\## Core Rules
        \\- **Default**: Use bees for ALL task tracking (`bees create`, `bees ready`, `bees close`)
        \\- **Prohibited**: Do NOT use TodoWrite, TaskCreate, or markdown files for task tracking
        \\- **Workflow**: Create bees issue BEFORE writing code, mark in_progress when starting
        \\- Check `bees ready` for available work at start of session
        \\
        \\## Essential Commands
        \\
        \\### Finding Work
        \\- `bees ready` - Show issues ready to work (no blockers)
        \\- `bees list` or `bees ls` - All open issues
        \\- `bees list --status=in_progress` - Active work
        \\- `bees show <id>` - Detailed issue view with dependencies
        \\
        \\### Creating & Updating
        \\- `bees create "<title>" -t task|bug|feature|epic|chore` - New issue
        \\  - Priority: `-p 1` through `-p 4` (1=critical, 2=medium, 4=backlog)
        \\- `bees update <id> --status in_progress` - Claim work
        \\- `bees update <id> --assignee username` - Assign to someone
        \\- `bees close <id>` - Mark complete
        \\- `bees close <id> --reason "explanation"` - Close with reason
        \\
        \\### Dependencies
        \\- `bees dep add <issue> <depends-on>` - Add dependency
        \\- `bees show <id>` - See what's blocking/blocked by this issue
        \\
        \\### Labels & Comments
        \\- `bees label add <id> <label>` - Add a label
        \\- `bees label remove <id> <label>` - Remove a label
        \\
        \\### Project Health
        \\- `bees ready` - Issues with no blockers
        \\- `bees list` - All open issues with status
        \\
        \\## Common Workflows
        \\
        \\**Starting work:**
        \\```bash
        \\bees ready                              # Find available work
        \\bees show <id>                          # Review issue details
        \\bees update <id> --status in_progress   # Claim it
        \\```
        \\
        \\**Completing work:**
        \\```bash
        \\bees close <id>                         # Mark complete
        \\```
        \\
        \\**Creating dependent work:**
        \\```bash
        \\bees create "Implement feature X" -t feature
        \\bees create "Write tests for X" -t task
        \\bees dep add <test-id> <feature-id>     # Tests depend on feature
        \\```
        \\
    );
}
