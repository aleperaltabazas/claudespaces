# Haskell Rewrite — Faithful Port

**Date:** 2026-06-08
**Scope:** Step 1 of 2. Replace the Python implementation with Haskell, preserving all external behavior, state file formats, and Docker interactions. Step 2 (idiomatic redesign) gets its own spec later.

## Motivation

- Native binary — no venv, no `pip install`, single executable
- Stronger type system — config parsing, workspace state, mount validation all benefit
- Author familiarity — more productive in Haskell than Python for this kind of tool

## Key Decisions

- **Build tool:** Stack
- **Docker interaction:** Shell out to `docker` CLI everywhere; no Docker SDK. Use `--format json` where structured output is needed, exit codes elsewhere.
- **HTTP server:** Scotty (thin wrapper over Warp) for the host bridge — one `POST /run` route
- **CLI parsing:** optparse-applicative
- **Config/state:** `yaml` + `aeson` for YAML config and JSON workspace state
- **Testing:** Hspec + Hedgehog. Test pure logic thoroughly, don't mock IO. Optional integration tests behind env var for later.
- **No `questionary` equivalent** — the CLI is fully non-interactive; the Python dependency was unused.

## Project Structure

```
claudespaces/
├── app/
│   └── Main.hs                  -- main = Cli.run
├── src/
│   └── Claudespaces/
│       ├── Cli.hs               -- optparse-applicative commands
│       ├── Config.hs            -- YAML loading & merging
│       ├── Container.hs         -- docker CLI shell-outs
│       ├── HostConfig.hs        -- bridge config + shims
│       ├── HostServer.hs        -- scotty HTTP server
│       ├── Image.hs             -- image resolution & build
│       └── Workspaces.hs        -- JSON state CRUD
├── test/
│   ├── Spec.hs                  -- hspec-discover entry point
│   └── Claudespaces/
│       ├── ConfigSpec.hs
│       ├── ContainerSpec.hs
│       ├── HostConfigSpec.hs
│       ├── ImageSpec.hs
│       └── WorkspacesSpec.hs
├── support/
│   ├── Dockerfile.base
│   └── bin/
│       ├── entrypoint.sh
│       └── claudespaces-host
├── package.yaml
├── stack.yaml
└── CLAUDE.md
```

`support/` files are container-side assets, unchanged from the Python version. Embedded into the binary at compile time via `file-embed` so distribution is a single executable.

## Dependencies

| Library                | Purpose                                                                             |
| ---------------------- | ----------------------------------------------------------------------------------- |
| `aeson`                | JSON encoding/decoding for workspace state                                          |
| `yaml`                 | YAML config parsing (uses aeson under the hood)                                     |
| `optparse-applicative` | CLI argument parsing                                                                |
| `scotty`               | Host bridge HTTP server                                                             |
| `process`              | Shell-outs to docker CLI                                                            |
| `directory`            | File/directory manipulation                                                         |
| `filepath`             | Path operations (`takeBaseName`, `</>`)                                             |
| `text`                 | Text handling (used by aeson, scotty, throughout)                                   |
| `text-conversions`     | Avoid boilerplate pack/unpack                                                       |
| `bytestring`           | File content hashing in Image.hs                                                    |
| `time`                 | ISO 8601 timestamps for workspace metadata                                          |
| `cryptohash-md5`       | Image tag hashing                                                                   |
| `file-embed`           | Embed support files (Dockerfile.base, entrypoint.sh, claudespaces-host) into binary |
| `hspec`                | Test runner                                                                         |
| `hedgehog`             | Property-based testing                                                              |
| `hspec-hedgehog`       | Integration between hspec and hedgehog                                              |

## Module Mapping

### Config.hs

Mirrors `config.py`. Pure logic except for file reads.

- `loadConfig :: FilePath -> IO Config` — reads global (`~/.config/claudespaces/claudespaces.yaml`) and local (`claudespaces.yml`), merges them. Errors if both `image` and `dockerfile` are set in either file.
- `parseMount :: Text -> Either Text Mount` — parses `src:dst` or `src:dst:ro|rw` strings.
- `Config` is a plain record: image, dockerfile, globalDockerfile, directories, additionalMounts.

### Workspaces.hs

Mirrors `workspaces.py`. JSON CRUD against `~/.claudespaces/workspaces.json`.

- `allWorkspaces`, `getByName`, `saveWorkspace`, `updateWorkspace`, `removeWorkspace` — standard CRUD.
- `healRunning :: Set ContainerId -> IO ()` — marks workspaces stopped if their container is no longer running.
- `generateName :: Set Text -> Text` — random adjective-noun pairs, same word lists as Python.
- `stateDir :: Text -> FilePath` — `~/.claudespaces/<name>`.
- `sessions.json` migration preserved for backwards compatibility.
- State file path exposed as a module-level value; tests override by writing to a temp directory.

### Image.hs

Mirrors `image.py`. Shell-outs to `docker build` and `docker image inspect`.

- `resolveImage :: Maybe Text -> Maybe FilePath -> Maybe FilePath -> IO Text` — same layered build chain: base image -> global dockerfile -> local dockerfile -> claudespaces-base intermediate.
- Image existence check: `docker image inspect <tag>` exit code.
- Build: `docker build --build-arg BASE_IMAGE=<base> -t <tag> -f <dockerfile> <context>` with stdout streaming.
- Tag generation: MD5 hash of Dockerfile.base + support files, same format `claudespaces-base:<slug>-<hash>`.

### Container.hs

Mirrors `container.py`. Shell-outs to docker CLI.

- `buildMounts :: [FilePath] -> FilePath -> Int -> [AdditionalMount] -> [MountSpec]` — pure function that computes the full mount list (workspace dirs, state mounts, entrypoint, host config, shims, claudespaces-host, additional mounts). This is the core testable logic.
- `createContainer :: CreateContainerOpts -> IO ContainerId` — calls `docker create` with all `--mount`, `-e`, `--add-host` flags.
- `attachContainer :: ContainerId -> IO ()` — `docker start <id>` then `docker exec -it -e TERM=... <id> /claudespaces/entrypoint.sh`. Uses `createProcess` with `delegate_ctlc = True` and inherited handles for TTY passthrough.
- `getRunningContainerIds :: IO (Set ContainerId)` — `docker ps -q --filter status=running`.
- `stopContainer`, `removeContainer` — straightforward shell-outs.
- Basename collision detection is pure and tested.

### HostConfig.hs

Mirrors `host_config.py`. Pure logic plus one file write.

- `loadHostBridge :: IO BridgeConfig` — merge builtin operations (notify) with user config from global YAML.
- `overridesManifest :: Operations -> Map Text Text` — pure, returns `{binary_name: op_name}` for operations with overrides.
- `writeShims :: Operations -> IO ()` — writes JSON manifest to `~/.claudespaces/shims.json`.

### HostServer.hs

Mirrors `host_server.py`. Scotty server plus process lifecycle.

- `runServer :: Int -> Operations -> IO ()` — Scotty app with single `POST /run` route.
- `handleRun :: Text -> Value -> Operations -> IO (Int, Value)` — core request handler, runs commands via `System.Process`. Supports sync and async (fire-and-forget) operations.
- `isRunning :: Int -> IO Bool` — check port with socket connect.
- `startServer :: IO ()` — spawn self as background process, record PID.
- `stopServerIfLast :: Text -> IO ()` — kill PID if no other running workspaces.

### Cli.hs

Mirrors `cli.py`. Wires everything together via optparse-applicative.

Subcommands: `new`, `start`, `stop`, `rm` (alias for `remove`), `ls` (alias for `list`).

Workspace lifecycle uses `bracket`/`finally` from `Control.Exception`: status set to "running" before `attachContainer`, set to "stopped" in the finally block. Handles `KeyboardInterrupt` (Haskell: `UserInterrupt` async exception).

Auto-heal on start: detects containers no longer running and marks their workspaces stopped.

## State File Compatibility

The Haskell binary is a drop-in replacement. Same JSON format for `workspaces.json`, same YAML format for config files, same paths. No migration required.

## Docker CLI Interface

| Operation          | Command                                                                                                                               |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------- |
| Check image exists | `docker image inspect <tag>` (exit code)                                                                                              |
| Build image        | `docker build --build-arg BASE_IMAGE=<base> -t <tag> -f <dockerfile> <context>`                                                       |
| List running       | `docker ps -q --filter status=running`                                                                                                |
| Create container   | `docker create --tty --interactive --user root -w /workspace --mount ... -e ... --add-host host.docker.internal:host-gateway <image>` |
| Start container    | `docker start <id>`                                                                                                                   |
| Attach (exec)      | `docker exec -it -e TERM=... <id> /claudespaces/entrypoint.sh`                                                                        |
| Stop container     | `docker stop <id>`                                                                                                                    |
| Remove container   | `docker rm -f <id>`                                                                                                                   |

## Testing Strategy

**Pure function tests (Hspec + Hedgehog):**

- **ConfigSpec** — YAML parsing, global+local merging, image/dockerfile mutual exclusion, mount parsing (valid and invalid formats), additional-mounts overlap detection.
- **WorkspacesSpec** — JSON round-tripping, CRUD operations, `healRunning` with various container ID sets, `generateName` uniqueness, `sessions.json` migration. Tests use a temp directory.
- **ContainerSpec** — mount list building (`buildMounts`): given dirs + state_dir + host config paths, assert correct mount specs. Basename collision detection. Environment variable assembly.
- **ImageSpec** — tag generation logic: MD5 hashing, slug building, intermediate tag format.
- **HostConfigSpec** — `overridesManifest`, merge of builtins with user operations, shims JSON output.

**Hedgehog property tests:**

- `parseMount` round-trips: generated valid mount strings always parse.
- `generateName` never collides with the provided existing name set.
- Config merging: local overrides global for `image`, directories are deduplicated.

**Not tested:** IO wrappers around docker CLI calls. Optional integration tests (actually hitting Docker) deferred to step 2.
