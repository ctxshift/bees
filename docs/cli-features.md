# Bees CLI Feature Matrix

Comparison of bees (Zig) CLI against the beads (Go) reference CLI.
Fields and commands related to Gastown, external trackers (Jira, GitHub), and
CI/deployment integration are intentionally excluded.

## Issue Content Fields

These are the rich-text fields that make an issue useful beyond just a title.

| Field | DB Column | beads CLI | bees CLI | Status |
|-------|-----------|-----------|----------|--------|
| title | `title` | positional arg | positional arg | Done |
| description | `description` | `-d, --description` | `-d, --description` | Done |
| design notes | `design` | `--design` | `--design` | Done |
| acceptance criteria | `acceptance_criteria` | `--acceptance` | `--acceptance` | Done |
| working notes | `notes` | `--notes` | `--notes` | Done |
| external reference | `external_ref` | `--external-ref` | `--external-ref` | Done |
| spec id | `spec_id` | `--spec-id` | -- | Won't implement |

### `edit` command (open $EDITOR)

Beads has `bd edit <id> [--design|--acceptance|--notes]` which opens `$EDITOR`
for multi-line editing of content fields.

| Feature | beads CLI | bees CLI | Status |
|---------|-----------|----------|--------|
| `edit <id>` (description) | `bd edit <id>` | `bees edit <id>` | Done |
| `edit <id> --design` | `bd edit <id> --design` | `bees edit <id> --design` | Done |
| `edit <id> --acceptance` | `bd edit <id> --acceptance` | `bees edit <id> --acceptance` | Done |
| `edit <id> --notes` | `bd edit <id> --notes` | `bees edit <id> --notes` | Done |

## Comments

| Feature | beads CLI | bees CLI | Status |
|---------|-----------|----------|--------|
| View comments | `bd show <id>` | `bees show <id>` | Done |
| Add comment | `bd comment add <id> "text"` | `bees comment add <id> "text"` | Done |
| List comments | `bd comment list <id>` | `bees comment list <id>` | Done |

## Core Issue Management

| Command | beads CLI | bees CLI | Status |
|---------|-----------|----------|--------|
| `init` | `bd init` | `bees init` | Done |
| `create` | `bd create` | `bees create` | Done |
| `list` / `ls` | `bd list` | `bees list` / `bees ls` | Done |
| `show` | `bd show` | `bees show` | Done |
| `update` | `bd update` | `bees update` | Done |
| `close` | `bd close` | `bees close` | Done |
| `ready` | `bd ready` | `bees ready` | Done |

## Create/Update Flag Coverage

| Flag | beads `create` | beads `update` | bees `create` | bees `update` | Status |
|------|---------------|----------------|---------------|---------------|--------|
| `-d, --description` | Y | Y | Y | Y | Done |
| `-t, --type` | Y | Y | Y | Y | Done |
| `-p, --priority` | Y | Y | Y | Y | Done |
| `-a, --assignee` | Y | Y | Y | Y | Done |
| `-o, --owner` | Y | Y | Y | Y | Done |
| `--title` | -- | Y | -- | Y | Done |
| `-s, --status` | -- | Y | -- | Y | Done |
| `--design` | Y | Y | Y | Y | Done |
| `--acceptance` | Y | Y | Y | Y | Done |
| `--notes` | Y | Y | Y | Y | Done |
| `--external-ref` | Y | Y | Y | Y | Done |
| `--due` | Y | Y | Y | Y | Done |
| `--defer` | Y | Y | Y | Y | Done |
| `--estimated` | Y | Y | -- | -- | Not implemented |
| `--pinned` | Y | Y | -- | -- | Not implemented |
| `-r, --reason` | -- | -- | -- (close) | -- | Done (close only) |
| `--json` | Y | Y | Y | Y | Done |

## Dependencies

| Feature | beads CLI | bees CLI | Status |
|---------|-----------|----------|--------|
| `dep add` | Y | Y | Done |
| `dep remove` | Y | Y | Done |
| `dep list` | Y | Y | Done |
| dep type: blocks | Y | Y | Done |
| dep type: related | Y | Y | Done |
| dep type: parent-child | Y | Y | Done |

## Labels

| Feature | beads CLI | bees CLI | Status |
|---------|-----------|----------|--------|
| `label add` | Y | Y | Done |
| `label remove` | Y | Y | Done |

## Utility Commands

| Command | beads CLI | bees CLI | Status |
|---------|-----------|----------|--------|
| `config get/set` | Y | Y | Done |
| `sync` (JSONL export) | Y | Y | Done |
| `prime` (AI context) | Y | Y | Done |
| `daemon start/stop/status` | -- | Y | Done (bees-only) |

## Intentionally Excluded

These beads features will **not** be implemented:

- Gastown integration (`--source-system`, sync with external trackers)
- GitHub PR fields (`pr_number`, `pr_url`, `pr_status`, `review_status`)
- Jira/Linear/external tracker sync
- Merge strategy and conflict resolution fields
- Integration/verification/rollback tracking
- Agent and molecule workflow fields
- `--spec-id` (spec document linking)
- Bulk import from external systems (`--file` for batch create)

## Remaining Work

### Nice to have

1. **`--estimated` flag** on create/update - DB column exists, need CLI flag
2. **`--pinned` flag** on create/update - DB column exists, need CLI flag
