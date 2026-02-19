const sqlite = @import("sqlite");

const Db = sqlite.Database;

const issues_ddl =
    \\CREATE TABLE IF NOT EXISTS issues (
    \\    id TEXT PRIMARY KEY,
    \\    title TEXT NOT NULL,
    \\    description TEXT,
    \\    status TEXT NOT NULL DEFAULT 'open',
    \\    priority INTEGER NOT NULL DEFAULT 2,
    \\    issue_type TEXT NOT NULL DEFAULT 'task',
    \\    assignee TEXT,
    \\    owner TEXT,
    \\    created_by TEXT,
    \\    created_at TEXT NOT NULL,
    \\    updated_at TEXT NOT NULL,
    \\    closed_at TEXT,
    \\    close_reason TEXT,
    \\    due_at TEXT,
    \\    defer_until TEXT,
    \\    estimated_minutes INTEGER,
    \\    external_ref TEXT,
    \\    pinned INTEGER NOT NULL DEFAULT 0,
    \\    is_template INTEGER NOT NULL DEFAULT 0,
    \\    ephemeral INTEGER NOT NULL DEFAULT 0,
    \\    metadata TEXT,
    \\    agent_id TEXT,
    \\    agent_status TEXT,
    \\    agent_context TEXT,
    \\    molecule_id TEXT,
    \\    molecule_type TEXT,
    \\    molecule_status TEXT,
    \\    parent_id TEXT,
    \\    source_branch TEXT,
    \\    target_branch TEXT,
    \\    worktree_path TEXT,
    \\    commit_sha TEXT,
    \\    pr_number INTEGER,
    \\    pr_url TEXT,
    \\    pr_status TEXT,
    \\    review_status TEXT,
    \\    merge_strategy TEXT,
    \\    conflict_files TEXT,
    \\    resolution_notes TEXT,
    \\    integration_status TEXT,
    \\    verification_status TEXT,
    \\    rollback_sha TEXT
    \\);
;

const dependencies_ddl =
    \\CREATE TABLE IF NOT EXISTS dependencies (
    \\    issue_id TEXT NOT NULL,
    \\    depends_on_id TEXT NOT NULL,
    \\    dep_type TEXT NOT NULL DEFAULT 'blocks',
    \\    created_at TEXT NOT NULL,
    \\    created_by TEXT,
    \\    PRIMARY KEY (issue_id, depends_on_id),
    \\    FOREIGN KEY (issue_id) REFERENCES issues(id),
    \\    FOREIGN KEY (depends_on_id) REFERENCES issues(id)
    \\);
;

const labels_ddl =
    \\CREATE TABLE IF NOT EXISTS labels (
    \\    issue_id TEXT NOT NULL,
    \\    label TEXT NOT NULL,
    \\    created_at TEXT NOT NULL,
    \\    PRIMARY KEY (issue_id, label),
    \\    FOREIGN KEY (issue_id) REFERENCES issues(id)
    \\);
;

const comments_ddl =
    \\CREATE TABLE IF NOT EXISTS comments (
    \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\    issue_id TEXT NOT NULL,
    \\    author TEXT,
    \\    text TEXT NOT NULL,
    \\    created_at TEXT NOT NULL,
    \\    FOREIGN KEY (issue_id) REFERENCES issues(id)
    \\);
;

const config_ddl =
    \\CREATE TABLE IF NOT EXISTS config (
    \\    key TEXT PRIMARY KEY,
    \\    value TEXT NOT NULL
    \\);
;

const metadata_ddl =
    \\CREATE TABLE IF NOT EXISTS metadata (
    \\    key TEXT PRIMARY KEY,
    \\    value TEXT NOT NULL
    \\);
;

const ready_view =
    \\CREATE VIEW IF NOT EXISTS ready_issues AS
    \\SELECT i.* FROM issues i
    \\WHERE i.status = 'open'
    \\  AND i.is_template = 0
    \\  AND i.ephemeral = 0
    \\  AND i.id NOT IN (
    \\    SELECT d.issue_id FROM dependencies d
    \\    JOIN issues blocker ON d.depends_on_id = blocker.id
    \\    WHERE d.dep_type = 'blocks'
    \\      AND blocker.status != 'closed'
    \\  );
;

const blocked_view =
    \\CREATE VIEW IF NOT EXISTS blocked_issues AS
    \\SELECT DISTINCT i.* FROM issues i
    \\JOIN dependencies d ON i.id = d.issue_id
    \\JOIN issues blocker ON d.depends_on_id = blocker.id
    \\WHERE d.dep_type = 'blocks'
    \\  AND blocker.status != 'closed';
;

pub fn init(db: sqlite.Database) !void {
    try db.exec(issues_ddl, .{});
    try db.exec(dependencies_ddl, .{});
    try db.exec(labels_ddl, .{});
    try db.exec(comments_ddl, .{});
    try db.exec(config_ddl, .{});
    try db.exec(metadata_ddl, .{});
    try db.exec(ready_view, .{});
    try db.exec(blocked_view, .{});

    // Schema migrations: add columns that may not exist in older databases
    inline for (.{
        "ALTER TABLE issues ADD COLUMN design TEXT",
        "ALTER TABLE issues ADD COLUMN acceptance_criteria TEXT",
        "ALTER TABLE issues ADD COLUMN notes TEXT",
    }) |ddl| {
        db.exec(ddl, .{}) catch {};
    }
}
