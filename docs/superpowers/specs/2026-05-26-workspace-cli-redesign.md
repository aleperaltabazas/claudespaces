# Workspace CLI Redesign

## Problem

The current CLI uses `claudespaces <dir>` as its entry point, which builds the image,
creates the container, and attaches in one shot. Users cannot prepare a workspace ahead
of time or give it a meaningful name without interactive prompting.

## Solution

Introduce explicit `new` and `start` commands. Provisioning and attaching are now
separate, deliberate steps. Terminology changes from "session" to "workspace" throughout.

## Commands

```
claudespaces new [--named <name>] [--start] [--image <img>] [--dockerfile <path>] <dir...>
claudespaces start <name>
claudespaces stop <name>
claudespaces remove <name>
claudespaces list
```

- **new**: builds the image (cached), creates the container in stopped state, saves the workspace.
  `--named` sets the name; omitted = auto-generated. `--start` attaches immediately after creation.
- **start**: attaches to a stopped workspace; errors if not found or already running.
- **stop / remove / list**: same behaviour as before, keyed by name instead of ID.

## Data Model

```json
{
  "name": "my-game",
  "dirs": ["/absolute/path/proj1"],
  "container_id": "sha256...",
  "image": "claudespaces-base:...",
  "created_at": "2026-05-26T...",
  "last_used_at": "2026-05-26T...",
  "status": "stopped"
}
```

State file: `~/.claudespaces/workspaces.json` (migrated from `sessions.json` on first load).

## Error Handling

| Situation | Message |
|-----------|---------|
| `new --named <x>` and `<x>` already exists | `Workspace '<x>' already exists.` |
| workspace not found | `Workspace '<name>' not found.` |
| `start` — already running | `Workspace '<name>' is already running.` |
| `stop` — already stopped | no-op + message |
| Docker not reachable | existing message, unchanged |

## Removed

- `claudespaces <dir>` bare-path entry point
- `_PathAwareGroup` routing hack
- `deduplicate_sessions` / one-session-per-dir enforcement
- Session `id` field (name is now the primary key)
