# Rebuild Subcommand Design

## Summary

Add a `rebuild` subcommand that regenerates the Docker image and container for an existing workspace while preserving claudespaces' internal state (workspace JSON, state dir with `claude.json` and `projects/`).

## CLI Interface

```
claudespaces rebuild NAME [--image IMAGE] [--dockerfile PATH] [--start]
```

- `NAME` — positional arg, the workspace name (required)
- `--image` / `-i` — override base Docker image
- `--dockerfile` / `-d` — override Dockerfile path
- `--start` / `-s` — attach to the workspace after rebuild

## Implementation

All changes are in `Cli.hs`. No new modules, no data model changes.

### New types

Add `Rebuild RebuildOpts` to the `Command` ADT:

```haskell
data RebuildOpts = RebuildOpts
  { name       :: Text
  , image      :: Maybe Text
  , dockerfile :: Maybe String
  , start      :: Bool
  }
```

### Parser

Register `rebuild` in the subparser block. Parser takes a positional `NAME` plus optional `--image`, `--dockerfile`, and `--start` flags (same definitions as `new`).

### `cmdRebuild` logic

1. Load workspace by name — error with `WorkspaceNotFound` if absent.
2. Check Docker is reachable.
3. Heal stale workspaces.
4. Reload workspace after heal — error with `WorkspaceAlreadyRunning` if status is `Running`.
5. Load config from CWD + global config path.
6. Determine image/dockerfile: CLI flags take precedence, then config values, then defaults.
7. Call `resolveImage` with full chain (base -> global dockerfile -> local dockerfile -> claudespaces-base layer).
8. Remove old container with `Container.removeContainer`.
9. Build mounts and create new container (same sequence as `cmdNew`: `checkBasenameCollision`, `buildMounts`, `resolveHostMounts`, `buildEnv`, `createContainer`).
10. Update workspace record: set new `containerId` and `image`.
11. Print "Rebuilt workspace: NAME".
12. If `--start`, call `attachWithCleanup`.

### Error handling

Reuses existing error types — no new `AppError` constructors needed:

- `WorkspaceNotFound` — workspace doesn't exist
- `WorkspaceAlreadyRunning` — must stop before rebuilding
- `DockerNotReachable` — Docker daemon not available
- `DockerfileNotFound` / `DockerBuildFailed` — image resolution failures
- `BasenameCollision` — directory basename conflict

### State preservation

The workspace's state dir (`~/.claudespaces/<name>/`) is untouched. It contains `claude.json` and `projects/` which hold Claude's session data. Only the Docker container and image reference are replaced.

### What gets pruned

The old container is removed via `docker rm -f`. Old images are not explicitly pruned — they remain available for other workspaces or manual cleanup with `docker image prune`.
