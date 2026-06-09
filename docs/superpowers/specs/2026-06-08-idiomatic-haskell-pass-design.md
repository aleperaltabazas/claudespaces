# Idiomatic Haskell Second Pass

## Overview

Refactor the claudespaces codebase from a direct Python-to-Haskell transliteration into idiomatic Haskell. The code is functionally correct; this pass improves types, structure, and style without changing behavior.

## 1. Language Extensions (project-wide)

Add to `package.yaml` under `default-extensions`:

- `OverloadedStrings` (already used per-file; promote to global)
- `OverloadedRecordDot`
- `DuplicateRecordFields`
- `ScopedTypeVariables` (already used per-file; promote to global)

## 2. New Modules

### `Claudespaces.Error`

Sum type for all domain errors:

```haskell
data AppError
  = ConfigError Text
  | WorkspaceNotFound Text
  | WorkspaceAlreadyExists Text
  | WorkspaceAlreadyRunning Text
  | WorkspaceAlreadyStopped Text
  | DockerNotReachable
  | DockerBuildFailed Text
  | DockerfileNotFound FilePath
  | BasenameCollision String
  | MountOverlap [Text]
  | InvalidMount Text
  | NameGenerationFailed
  | HomeNotSet
  deriving (Show)

instance Exception AppError
```

Replaces all `throwIO (userError ...)` and `ioError (userError ...)` calls.

### `Claudespaces.Env`

```haskell
data Env = Env
  { home            :: FilePath
  , stateFile       :: FilePath
  , globalConfigPath :: FilePath
  , shimsPath       :: FilePath
  }

type App = ReaderT Env IO

mkEnv :: IO Env
```

`mkEnv` reads `HOME`, computes the derived paths, and returns `Env`. Called once in `Cli.run`.

### `Claudespaces.Lifecycle`

Extracted from `Cli.hs`. Contains the shared orchestration patterns:

- `attachWithCleanup :: Text -> Text -> App ()` -- start bridge, set running, attach container, finally stop + heal. Used by `cmdNew --start` and `cmdStart`.
- `healStaleWorkspaces :: App ()` -- get running container IDs, call `Workspaces.healRunning`.
- `ensureBridge :: Int -> IO ()` -- check if bridge is running, start if not.

### `Claudespaces.Workspaces.Internal`

Exports `adjectives` and `nouns` word lists (needed by tests/property checks). The main `Workspaces` module re-exports everything except these.

## 3. Type Changes

### Status ADT (`Workspaces.hs`)

```haskell
data Status = Running | Stopped deriving (Eq, Show)
```

`FromJSON`/`ToJSON` serialize to/from `"running"`/`"stopped"` for backwards compatibility with `workspaces.json`.

`Workspace.status :: Status` replaces `wsStatus :: Text`.

### Merge `MountSpec` + `MountEntry` into `Mount` (`Config.hs`)

```haskell
data Mount = Mount
  { source   :: Text
  , target   :: Text
  , readOnly :: Bool
  } deriving (Eq, Show)
```

`Container.hs` drops its `MountSpec` type and imports `Mount` from `Config`. All functions that took `MountSpec` or `MountEntry` now take `Mount`.

### Drop field prefixes (all records)

With `OverloadedRecordDot` + `DuplicateRecordFields`, all field name prefixes are removed:

| Before                            | After                       |
| --------------------------------- | --------------------------- |
| `cfgImage`                        | `image`                     |
| `cfgDockerfile`                   | `dockerfile`                |
| `cfgGlobalDockerfile`             | `globalDockerfile`          |
| `cfgDirectories`                  | `directories`               |
| `cfgAdditionalMounts`             | `additionalMounts`          |
| `wsName`                          | `name`                      |
| `wsDirs`                          | `dirs`                      |
| `wsContainerId`                   | `containerId`               |
| `wsImage`                         | `image`                     |
| `wsCreatedAt`                     | `createdAt`                 |
| `wsLastUsedAt`                    | `lastUsedAt`                |
| `wsStatus`                        | `status`                    |
| `mSource` / `mountSource`         | `source`                    |
| `mTarget` / `mountTarget`         | `target`                    |
| `mReadOnly` / `mountReadOnly`     | `readOnly`                  |
| `opCommand`                       | `command`                   |
| `opArgs`                          | `args`                      |
| `opAsync`                         | `async`                     |
| `opOverride`                      | `override`                  |
| `rawImage`, `rawDockerfile`, etc. | `image`, `dockerfile`, etc. |
| `bridgePort`                      | `port`                      |
| `bridgeOperations`                | `operations`                |

Field access changes from `wsName ws` to `ws.name`, `cfgImage cfg` to `cfg.image`, etc.

## 4. Module-by-Module Changes

### `Config.hs`

- `MountEntry` renamed to `Mount`, fields unprefixed
- `parseMount` returns `Either AppError Mount` (uses `InvalidMount`)
- `parseMounts` uses `traverse` instead of `mapM parseSingle` with manual error wrapping
- `validate` returns `Either AppError ()` instead of `IO ()`
- `checkOverlap` returns `Either AppError ()` instead of `IO ()`
- `loadConfig` throws `AppError` instead of `userError`
- `maybe [] id` becomes `fromMaybe []`

### `Workspaces.hs`

- `Status` ADT with JSON instances
- Field prefixes dropped
- `nameExists` uses `isJust`
- `generateName` throws `NameGenerationFailed` instead of `userError`
- `defaultStateFile` throws `HomeNotSet` instead of `userError`
- Word lists moved to `Workspaces.Internal`
- `if not exists then return () else ...` patterns replaced with `when`/`unless`/guards

### `Container.hs`

- `MountSpec` removed; imports `Mount` from `Config`
- `checkBasenameCollision` becomes pure: `[FilePath] -> Either AppError ()`
- `mountSpecToArgs` renamed to `mountToArgs`
- `buildMounts` returns `[Mount]` (was `[MountSpec]`)
- `resolveHostMounts` returns `IO [Mount]`
- `_ <- readProcess ...; return ()` becomes `void $ readProcess ...`

### `Image.hs`

- `maybe "ubuntu:24.04" id` becomes `fromMaybe "ubuntu:24.04"`
- `ioError (userError ...)` becomes `throwIO (DockerBuildFailed ...)` / `throwIO (DockerfileNotFound ...)`
- `checkExists` uses `unless` + `throwIO`

### `HostConfig.hs`

- `maybe defaultPort id` becomes `fromMaybe defaultPort`
- `maybe Map.empty id` becomes `fromMaybe Map.empty`
- Field prefixes dropped from `Operation` and `BridgeConfig`
- Unused `catch`/`SomeException` import removed

### `HostServer.hs`

- Minimal changes; already fairly clean
- `return $ case result of ...` becomes direct pattern match
- Field access updated for dot syntax

### `Cli.hs`

- Lifecycle logic extracted to `Lifecycle`
- Commands run in `App` monad, dispatched via `runReaderT`
- `if not ok then ... exitFailure else return ()` patterns become `unless ok $ throwIO DockerNotReachable` (caught at top level)
- Error display: top-level `catch` in `run` that pretty-prints `AppError` and calls `exitFailure`
- `collapseHome` and `stripPrefix'` stay as local helpers

## 5. Error Handling Strategy

`Cli.run` wraps the entire dispatch in a top-level handler:

```haskell
run :: IO ()
run = do
  env <- mkEnv
  cmd <- execParser opts
  runReaderT (dispatch cmd) env
    `catch` \(e :: AppError) -> do
      hPutStrLn stderr $ "Error: " <> displayError e
      exitFailure
```

`displayError :: AppError -> String` provides user-friendly messages (no "user error" prefix). Individual commands throw `AppError` instead of printing + `exitFailure`.

Pure validation functions (`checkBasenameCollision`, `validate`, `checkOverlap`, `parseMount`) return `Either AppError a`. The calling IO code uses `either throwIO pure` to bridge into the exception world.

## 6. Test Changes

- Import `Mount` from `Config` instead of `MountEntry`/`MountSpec`
- Update field access to unprefixed names
- `checkBasenameCollision` tests change from `shouldThrow` to checking `Either` values
- Word list tests (if any) import from `Workspaces.Internal`
- Status comparisons use the `Status` ADT instead of text literals

## 7. Dependencies

Add to `package.yaml`:

- `mtl` (for `ReaderT`, `asks`, `liftIO` from `Control.Monad.Reader`)

No other new dependencies.

## 8. What Does NOT Change

- External behavior (CLI interface, JSON format, Docker commands)
- `package.yaml` structure (executable, library, test targets)
- Module file locations (all stay under `src/Claudespaces/`)
- Docker interaction approach (CLI shell-outs, no SDK)
- Test framework (Hspec + Hedgehog)
