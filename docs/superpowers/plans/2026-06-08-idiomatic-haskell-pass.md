# Idiomatic Haskell Second Pass — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor the claudespaces codebase from a direct Python transliteration into idiomatic Haskell — better types, cleaner error handling, less duplication — without changing external behavior.

**Architecture:** Introduce `Error` (sum type), `Env` (ReaderT-based app monad), and `Lifecycle` (shared orchestration) modules. Merge duplicate mount types, add a `Status` ADT, drop field prefixes via `OverloadedRecordDot`, and replace all `userError` calls with typed `AppError` exceptions.

**Tech Stack:** Same as before (Stack, optparse-applicative, aeson, yaml, scotty, hspec, hedgehog) plus `mtl` for `ReaderT`.

---

## File Map

**Create:**
- `src/Claudespaces/Error.hs` — `AppError` sum type with `Exception` instance and `displayError`
- `src/Claudespaces/Env.hs` — `Env` record, `App` type alias, `mkEnv`
- `src/Claudespaces/Lifecycle.hs` — `attachWithCleanup`, `healStaleWorkspaces`, `ensureBridge`
- `src/Claudespaces/Workspaces/Internal.hs` — word lists (`adjectives`, `nouns`)

**Modify:**
- `package.yaml` — add `default-extensions`, add `mtl` dep, add new modules
- `src/Claudespaces/Config.hs` — rename `MountEntry` → `Mount`, drop prefixes, use `AppError`
- `src/Claudespaces/Workspaces.hs` — add `Status` ADT, drop prefixes, import from `Internal`
- `src/Claudespaces/Container.hs` — drop `MountSpec`, import `Mount` from `Config`, pure `checkBasenameCollision`
- `src/Claudespaces/Image.hs` — use `AppError`, `fromMaybe`, `unless`
- `src/Claudespaces/HostConfig.hs` — drop prefixes, `fromMaybe`, clean imports
- `src/Claudespaces/HostServer.hs` — update field access for dot syntax
- `src/Claudespaces/Cli.hs` — use `App` monad, extract lifecycle, top-level error handler
- `test/Claudespaces/ConfigSpec.hs` — `MountEntry` → `Mount`, unprefixed fields
- `test/Claudespaces/WorkspacesSpec.hs` — `Status` ADT, unprefixed fields
- `test/Claudespaces/ContainerSpec.hs` — `MountSpec` → `Mount`, `Either`-based collision tests
- `test/Claudespaces/ImageSpec.hs` — minor: field access updates
- `test/Claudespaces/HostConfigSpec.hs` — unprefixed fields

---

### Task 1: Add language extensions and `mtl` dependency

**Files:**
- Modify: `package.yaml`

- [ ] **Step 1: Add default-extensions and mtl to package.yaml**

Add `default-extensions` under the top-level `library` key and to each target. The simplest approach: add it at the top level so it applies everywhere.

```yaml
default-extensions:
  - OverloadedStrings
  - OverloadedRecordDot
  - DuplicateRecordFields
  - ScopedTypeVariables
```

Add `mtl` to the `dependencies` list.

- [ ] **Step 2: Remove per-file LANGUAGE pragmas that are now global**

In every `.hs` file under `src/` and `test/`, remove:
- `{-# LANGUAGE OverloadedStrings #-}`
- `{-# LANGUAGE ScopedTypeVariables #-}`

Leave any other pragmas in place.

- [ ] **Step 3: Verify it builds and tests pass**

Run: `stack build && stack test`

Expected: 72 tests pass, no compilation errors.

- [ ] **Step 4: Commit**

```bash
git add package.yaml src/ test/
git commit -m "chore: promote language extensions to default-extensions, add mtl"
```

---

### Task 2: Add Error module

**Files:**
- Create: `src/Claudespaces/Error.hs`
- Modify: `package.yaml` (add to exposed-modules)

- [ ] **Step 1: Create `src/Claudespaces/Error.hs`**

```haskell
module Claudespaces.Error
  ( AppError (..)
  , displayError
  ) where

import Control.Exception (Exception)
import Data.Text (Text)
import qualified Data.Text as T

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

displayError :: AppError -> String
displayError (ConfigError msg)             = "Config error: " <> T.unpack msg
displayError (WorkspaceNotFound name)      = "Workspace '" <> T.unpack name <> "' not found"
displayError (WorkspaceAlreadyExists name) = "Workspace '" <> T.unpack name <> "' already exists"
displayError (WorkspaceAlreadyRunning name) = "Workspace '" <> T.unpack name <> "' is already running"
displayError (WorkspaceAlreadyStopped name) = "Workspace '" <> T.unpack name <> "' is already stopped"
displayError DockerNotReachable            = "Docker is not running or not reachable"
displayError (DockerBuildFailed msg)       = "Docker build failed: " <> T.unpack msg
displayError (DockerfileNotFound path)     = "Dockerfile not found: " <> path
displayError (BasenameCollision name)      = "Basename collision: multiple directories share the basename '" <> name <> "'"
displayError (MountOverlap targets)        = "Overlapping container mount targets: " <> T.unpack (T.intercalate ", " targets)
displayError (InvalidMount msg)            = "Invalid mount: " <> T.unpack msg
displayError NameGenerationFailed          = "Could not generate a unique workspace name"
displayError HomeNotSet                    = "HOME environment variable not set"
```

- [ ] **Step 2: Add to exposed-modules in package.yaml**

Add `Claudespaces.Error` to the `exposed-modules` list.

- [ ] **Step 3: Verify it builds**

Run: `stack build`

Expected: compiles (module not imported anywhere yet).

- [ ] **Step 4: Commit**

```bash
git add src/Claudespaces/Error.hs package.yaml
git commit -m "feat: add Error module with AppError sum type"
```

---

### Task 3: Add Env module

**Files:**
- Create: `src/Claudespaces/Env.hs`
- Modify: `package.yaml` (add to exposed-modules)

- [ ] **Step 1: Create `src/Claudespaces/Env.hs`**

```haskell
module Claudespaces.Env
  ( Env (..)
  , App
  , mkEnv
  ) where

import Control.Exception (throwIO)
import Control.Monad.Reader (ReaderT)
import System.Environment (lookupEnv)
import System.FilePath ((</>))

import Claudespaces.Error (AppError (..))

data Env = Env
  { home             :: FilePath
  , stateFile        :: FilePath
  , globalConfigPath :: FilePath
  , shimsPath        :: FilePath
  }

type App = ReaderT Env IO

mkEnv :: IO Env
mkEnv = do
  mHome <- lookupEnv "HOME"
  case mHome of
    Nothing -> throwIO HomeNotSet
    Just h  -> pure Env
      { home             = h
      , stateFile        = h </> ".claudespaces" </> "workspaces.json"
      , globalConfigPath = h </> ".config" </> "claudespaces" </> "claudespaces.yaml"
      , shimsPath        = h </> ".claudespaces" </> "shims.json"
      }
```

- [ ] **Step 2: Add to exposed-modules in package.yaml**

Add `Claudespaces.Env` to the `exposed-modules` list.

- [ ] **Step 3: Verify it builds**

Run: `stack build`

- [ ] **Step 4: Commit**

```bash
git add src/Claudespaces/Env.hs package.yaml
git commit -m "feat: add Env module with App monad and mkEnv"
```

---

### Task 4: Refactor Config.hs — rename types, drop prefixes, use AppError

**Files:**
- Modify: `src/Claudespaces/Config.hs`
- Modify: `test/Claudespaces/ConfigSpec.hs`

This is the largest single change because `Mount` and `Config` fields are referenced across many modules. We update Config and its tests first, then fix downstream consumers in later tasks.

- [ ] **Step 1: Update Config.hs**

Key changes:
- `MountEntry` → `Mount` with fields `source`, `target`, `readOnly` (no prefix)
- `Config` fields: `cfgImage` → `image`, `cfgDockerfile` → `dockerfile`, `cfgGlobalDockerfile` → `globalDockerfile`, `cfgDirectories` → `directories`, `cfgAdditionalMounts` → `additionalMounts`
- `RawConfig` fields: `rawImage` → `image`, `rawDockerfile` → `dockerfile`, `rawDirectories` → `directories`, `rawAdditionalMounts` → `additionalMounts` (disambiguation handled by `DuplicateRecordFields`)
- `parseMount` returns `Either AppError Mount` (uses `InvalidMount`)
- `validate` returns `Either AppError ()`
- `checkOverlap` returns `Either AppError ()`
- `loadConfig` calls `either throwIO pure` to bridge pure validation into IO
- `maybe [] id` → `fromMaybe []`
- Import `Claudespaces.Error`

```haskell
module Claudespaces.Config
  ( Config (..)
  , Mount (..)
  , emptyConfig
  , loadConfig
  , parseMount
  ) where

import Control.Exception  (throwIO)
import Data.List          (nub)
import Data.Maybe         (fromMaybe)
import Data.Aeson         (FromJSON (..), withObject, (.:?), (.!=))
import qualified Data.ByteString as BS
import qualified Data.Set        as Set
import Data.Text          (Text)
import qualified Data.Text as T
import Data.Yaml          (decodeThrow)
import System.Directory   (doesFileExist)
import System.FilePath    ((</>))

import Claudespaces.Error (AppError (..))

data Mount = Mount
  { source   :: Text
  , target   :: Text
  , readOnly :: Bool
  } deriving (Eq, Show)

data Config = Config
  { image            :: Maybe Text
  , dockerfile       :: Maybe Text
  , globalDockerfile :: Maybe Text
  , directories      :: [Text]
  , additionalMounts :: [Mount]
  } deriving (Eq, Show)

emptyConfig :: Config
emptyConfig = Config Nothing Nothing Nothing [] []

data RawConfig = RawConfig
  { rawImage      :: Maybe Text
  , rawDockerfile :: Maybe Text
  , rawDirs       :: [Text]
  , rawMounts     :: [Text]
  } deriving (Eq, Show)

emptyRaw :: RawConfig
emptyRaw = RawConfig Nothing Nothing [] []

instance FromJSON RawConfig where
  parseJSON = withObject "RawConfig" $ \o ->
    RawConfig
      <$> o .:? "image"
      <*> o .:? "dockerfile"
      <*> (fromMaybe [] <$> o .:? "directories")
      <*> (fromMaybe [] <$> o .:? "additional-mounts")

parseMount :: Text -> Either AppError Mount
parseMount raw =
  case T.splitOn ":" raw of
    [src, dst]       -> Right $ Mount src dst False
    [src, dst, mode] ->
      case mode of
        "ro" -> Right $ Mount src dst True
        "rw" -> Right $ Mount src dst False
        _    -> Left $ InvalidMount $ "Invalid mount mode: " <> mode
    _ -> Left $ InvalidMount $ "Invalid mount entry (expected src:dst or src:dst:ro|rw): " <> raw

validate :: String -> RawConfig -> Either AppError ()
validate label rc =
  case (rawImage rc, rawDockerfile rc) of
    (Just _, Just _) -> Left $ ConfigError $ T.pack $ label <> ": cannot specify both 'image' and 'dockerfile'"
    _                -> Right ()

checkOverlap :: [Mount] -> [Mount] -> Either AppError ()
checkOverlap globalMounts localMounts =
  let globalTargets = Set.fromList (map (.target) globalMounts)
      localTargets  = Set.fromList (map (.target) localMounts)
      overlap       = Set.intersection globalTargets localTargets
  in if Set.null overlap
       then Right ()
       else Left $ MountOverlap (Set.toAscList overlap)

parseMounts :: [Text] -> Either AppError [Mount]
parseMounts = traverse parseMount

loadConfig :: FilePath -> FilePath -> IO Config
loadConfig cwd globalPath = do
  global <- loadYaml globalPath
  local  <- loadYaml (cwd </> "claudespaces.yml")

  either throwIO pure $ validate "global config" global
  either throwIO pure $ validate "local config"  local

  mounts <- either throwIO pure $ do
    gm <- parseMounts (rawMounts global)
    lm <- parseMounts (rawMounts local)
    checkOverlap gm lm
    pure (gm ++ lm)

  let mergedImage = case rawImage local of
        Just _  -> rawImage local
        Nothing -> rawImage global

  pure Config
    { image            = mergedImage
    , dockerfile       = rawDockerfile local
    , globalDockerfile = rawDockerfile global
    , directories      = nub (rawDirs global ++ rawDirs local)
    , additionalMounts = mounts
    }

loadYaml :: FilePath -> IO RawConfig
loadYaml path = do
  exists <- doesFileExist path
  if not exists
    then pure emptyRaw
    else do
      bs <- BS.readFile path
      if BS.null bs
        then pure emptyRaw
        else decodeThrow bs
```

- [ ] **Step 2: Update ConfigSpec.hs**

Replace all `MountEntry` with `Mount`. Replace all `cfgImage` with `.image`, `cfgDockerfile` with `.dockerfile`, etc. Example changes:

```haskell
-- Before:
parseMount "/host:/ctr" `shouldBe` Right (MountEntry "/host" "/ctr" False)
cfgImage cfg `shouldBe` Just "ubuntu:24.04"

-- After:
parseMount "/host:/ctr" `shouldBe` Right (Mount "/host" "/ctr" False)
cfg.image `shouldBe` Just "ubuntu:24.04"
```

Apply this pattern to every test in the file. Also update the `isLeft` helper to work with `Either AppError b`.

- [ ] **Step 3: Verify Config tests pass**

Run: `stack test --test-arguments '--match Config'`

Expected: all Config tests pass.

- [ ] **Step 4: Commit**

```bash
git add src/Claudespaces/Config.hs test/Claudespaces/ConfigSpec.hs
git commit -m "refactor: Config uses Mount, AppError, dot syntax, drop prefixes"
```

---

### Task 5: Refactor Workspaces.hs — Status ADT, drop prefixes, Internal module

**Files:**
- Create: `src/Claudespaces/Workspaces/Internal.hs`
- Modify: `src/Claudespaces/Workspaces.hs`
- Modify: `test/Claudespaces/WorkspacesSpec.hs`
- Modify: `package.yaml` (add Internal to exposed-modules)

- [ ] **Step 1: Create `src/Claudespaces/Workspaces/Internal.hs`**

```haskell
module Claudespaces.Workspaces.Internal
  ( adjectives
  , nouns
  ) where

import Data.Text (Text)

adjectives :: [Text]
adjectives =
  [ "bold", "calm", "dark", "deep", "fast", "free", "hard", "high"
  , "kind", "last", "late", "long", "loud", "mild", "near", "next"
  , "nice", "open", "pure", "rare", "real", "rich", "safe", "slim"
  , "slow", "soft", "tall", "thin", "tiny", "vast", "warm", "wide"
  , "wild", "wise", "blue", "cold", "cool", "dull", "fair", "firm"
  , "flat", "full", "gray", "keen", "lazy", "lean", "live", "lost"
  , "mad",  "neat"
  ]

nouns :: [Text]
nouns =
  [ "space", "orbit", "comet", "cloud", "creek", "delta", "drift"
  , "dusk",  "echo",  "field", "flame", "flare", "flash", "flow"
  , "forge", "frost", "glade", "gleam", "grove", "haven", "haze"
  , "isle",  "lake",  "leap",  "light", "lodge", "loom",  "lunar"
  , "marsh", "mist",  "moon",  "moss",  "nova",  "ocean", "peak"
  , "plain", "prism", "pulse", "ridge", "rift",  "river", "rock"
  , "shade", "shore", "sky",   "slope", "snow",  "solar", "spark"
  , "star",  "stone"
  ]
```

- [ ] **Step 2: Update Workspaces.hs**

Key changes:
- Add `Status` ADT (`Running | Stopped`) with `FromJSON`/`ToJSON` instances serializing to/from `"running"`/`"stopped"`
- `wsStatus :: Text` → `status :: Status`
- All field prefixes dropped: `wsName` → `name`, `wsDirs` → `dirs`, `wsContainerId` → `containerId`, `wsImage` → `image`, `wsCreatedAt` → `createdAt`, `wsLastUsedAt` → `lastUsedAt`
- Word lists removed from this file; imported from `Workspaces.Internal`
- `generateName` throws `NameGenerationFailed` instead of `userError`
- `defaultStateFile` throws `HomeNotSet` instead of `userError`
- `nameExists` uses `isJust`
- `if not exists then return () else ...` → `unless`/`when`/guards
- Export list: keep exporting `adjectives` and `nouns` (re-exported from Internal) for backwards compat with tests
- Import `Claudespaces.Error`

The `FromJSON`/`ToJSON` instances for `Workspace` need updating for the new field names. The JSON keys stay the same (`"name"`, `"status"`, `"container_id"`, etc.) — only the Haskell field names change.

The `Status` JSON instances:
```haskell
instance FromJSON Status where
  parseJSON = withText "Status" $ \case
    "running" -> pure Running
    "stopped" -> pure Stopped
    other     -> fail $ "Unknown status: " <> T.unpack other

instance ToJSON Status where
  toJSON Running = String "running"
  toJSON Stopped = String "stopped"
```

Add `{-# LANGUAGE LambdaCase #-}` to the file (not in default-extensions — only used here).

- [ ] **Step 3: Update WorkspacesSpec.hs**

Replace all field access: `wsName (head result)` → `(.name) (head result)` or `(head result).name`. Replace `wsStatus` → `.status`, comparisons with `"running"` → `Running`, `"stopped"` → `Stopped`. Replace `sampleWorkspace` field names. Import `Status(..)`.

Example:
```haskell
-- Before:
fmap wsStatus result `shouldBe` Just "running"

-- After:
fmap (.status) result `shouldBe` Just Running
```

The word list collision test should import `adjectives` and `nouns` from `Claudespaces.Workspaces` (which re-exports from Internal) — no import change needed.

- [ ] **Step 4: Verify Workspaces tests pass**

Run: `stack test --test-arguments '--match Workspaces'`

Expected: all Workspaces tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/Claudespaces/Workspaces/ src/Claudespaces/Workspaces.hs test/Claudespaces/WorkspacesSpec.hs package.yaml
git commit -m "refactor: Workspaces uses Status ADT, drop prefixes, extract Internal"
```

---

### Task 6: Refactor Container.hs — drop MountSpec, use Mount, pure collision check

**Files:**
- Modify: `src/Claudespaces/Container.hs`
- Modify: `test/Claudespaces/ContainerSpec.hs`

- [ ] **Step 1: Update Container.hs**

Key changes:
- Remove `MountSpec` type entirely
- Import `Mount(..)` from `Claudespaces.Config`
- `buildMounts` returns `[Mount]` instead of `[MountSpec]`
- `hostClaudePaths` unchanged
- `resolveHostMounts` returns `IO [Mount]`
- `mountSpecToArgs` → `mountToArgs`, takes `Mount`
- `createContainer` takes `[Mount]` instead of `[MountSpec]`
- `checkBasenameCollision` becomes pure: `[FilePath] -> Either AppError ()`
- `_ <- readProcess ...; return ()` → `void $ readProcess ...`
- Import `Claudespaces.Error`
- All field access uses dot syntax: `m.source`, `m.target`, `m.readOnly`

For `checkBasenameCollision`:
```haskell
checkBasenameCollision :: [FilePath] -> Either AppError ()
checkBasenameCollision dirs =
  let basenames = map takeBaseName dirs
      dups = map head . filter ((> 1) . length) . group . sort $ basenames
  in case dups of
    []    -> Right ()
    (d:_) -> Left $ BasenameCollision d
```

- [ ] **Step 2: Update ContainerSpec.hs**

- Import `Mount(..)` from `Config` instead of `MountEntry`
- Replace `MountEntry` with `Mount` in test data
- Replace `mTarget`, `mSource`, `mReadOnly` with `.target`, `.source`, `.readOnly`
- `checkBasenameCollision` tests change from `shouldThrow` to checking `Either`:

```haskell
-- Before:
checkBasenameCollision ["/group1/myapp", "/group2/myapp"]
  `shouldThrow` anyIOException

-- After:
checkBasenameCollision ["/group1/myapp", "/group2/myapp"]
  `shouldSatisfy` isLeft

-- Before:
checkBasenameCollision ["/group1/app", "/group2/web"]

-- After:
checkBasenameCollision ["/group1/app", "/group2/web"]
  `shouldBe` Right ()
```

Add a local `isLeft` helper if not already present.

- [ ] **Step 3: Verify Container tests pass**

Run: `stack test --test-arguments '--match Container'`

Expected: all Container tests pass.

- [ ] **Step 4: Commit**

```bash
git add src/Claudespaces/Container.hs test/Claudespaces/ContainerSpec.hs
git commit -m "refactor: Container uses Mount from Config, pure collision check, drop MountSpec"
```

---

### Task 7: Refactor Image.hs — AppError, fromMaybe, unless

**Files:**
- Modify: `src/Claudespaces/Image.hs`
- Modify: `test/Claudespaces/ImageSpec.hs` (minor)

- [ ] **Step 1: Update Image.hs**

Key changes:
- `maybe "ubuntu:24.04" id` → `fromMaybe "ubuntu:24.04"`
- `ioError (userError ...)` → `throwIO (DockerBuildFailed ...)` and `throwIO (DockerfileNotFound ...)`
- `checkExists` uses `unless`:
  ```haskell
  checkExists path = do
    ok <- doesFileExist path
    unless ok $ throwIO (DockerfileNotFound path)
  ```
- Import `Claudespaces.Error`, `Control.Monad (unless)`, `Data.Maybe (fromMaybe)`

- [ ] **Step 2: Update ImageSpec.hs (minor)**

No structural changes needed — the tests only use pure functions (`sanitizeTag`, `intermediateTag`, `globalTag`, `customTag`) which don't change signature. Just verify no field access patterns need updating.

- [ ] **Step 3: Verify Image tests pass**

Run: `stack test --test-arguments '--match Image'`

Expected: all Image tests pass.

- [ ] **Step 4: Commit**

```bash
git add src/Claudespaces/Image.hs test/Claudespaces/ImageSpec.hs
git commit -m "refactor: Image uses AppError, fromMaybe, unless"
```

---

### Task 8: Refactor HostConfig.hs — drop prefixes, fromMaybe, clean imports

**Files:**
- Modify: `src/Claudespaces/HostConfig.hs`
- Modify: `test/Claudespaces/HostConfigSpec.hs`

- [ ] **Step 1: Update HostConfig.hs**

Key changes:
- `Operation` fields: `opCommand` → `command`, `opArgs` → `args`, `opAsync` → `async`, `opOverride` → `override`
- `BridgeConfig` fields: `bridgePort` → `port`, `bridgeOperations` → `operations`
- `RawBridgeYaml` and `RawGlobalYaml` internal field names updated similarly
- `maybe defaultPort id` → `fromMaybe defaultPort`
- `maybe Map.empty id` → `fromMaybe Map.empty`
- Remove unused `catch`/`SomeException` import
- Field access in `overridesManifest` uses dot syntax: `op.override`, `op.command`
- `builtinOperations` uses unprefixed field names

- [ ] **Step 2: Update HostConfigSpec.hs**

Replace `bridgePort` → `.port`, `bridgeOperations` → `.operations`, `opCommand` → `.command` throughout.

Example:
```haskell
-- Before:
bridgePort cfg `shouldBe` 7731
opCommand op `shouldBe` "custom-notify {msg}"

-- After:
cfg.port `shouldBe` 7731
op.command `shouldBe` "custom-notify {msg}"
```

- [ ] **Step 3: Verify HostConfig tests pass**

Run: `stack test --test-arguments '--match HostConfig'`

Expected: all HostConfig tests pass.

- [ ] **Step 4: Commit**

```bash
git add src/Claudespaces/HostConfig.hs test/Claudespaces/HostConfigSpec.hs
git commit -m "refactor: HostConfig drops prefixes, uses fromMaybe, cleans imports"
```

---

### Task 9: Refactor HostServer.hs — update field access

**Files:**
- Modify: `src/Claudespaces/HostServer.hs`

- [ ] **Step 1: Update HostServer.hs**

Key changes:
- All `Operation` field access: `opCommand op` → `op.command`, `opArgs op` → `op.args`, `opAsync op` → `op.async`
- All `Workspace` field access: `wsName w` → `w.name`, `wsStatus w` → `w.status`
- `BridgeConfig` access if any: `bridgePort` → `.port`
- `return $ case result of ...` → direct pattern match where applicable
- `w.status` comparisons now use `Running`/`Stopped` constructors

- [ ] **Step 2: Verify it compiles**

Run: `stack build`

Expected: compiles. (No dedicated HostServer tests to run.)

- [ ] **Step 3: Commit**

```bash
git add src/Claudespaces/HostServer.hs
git commit -m "refactor: HostServer uses dot syntax for field access"
```

---

### Task 10: Add Lifecycle module, refactor Cli.hs

**Files:**
- Create: `src/Claudespaces/Lifecycle.hs`
- Modify: `src/Claudespaces/Cli.hs`
- Modify: `package.yaml` (add Lifecycle to exposed-modules)

This is the final task and the largest. It extracts duplicated orchestration logic from `Cli.hs` into `Lifecycle.hs` and converts `Cli.hs` to use the `App` monad with a top-level error handler.

- [ ] **Step 1: Create `src/Claudespaces/Lifecycle.hs`**

```haskell
module Claudespaces.Lifecycle
  ( attachWithCleanup
  , healStaleWorkspaces
  , ensureBridge
  ) where

import Control.Exception (finally)
import Control.Monad.Reader (asks, liftIO)
import Data.Text (Text)
import qualified Data.Text as T

import Claudespaces.Env (App, Env (..))
import qualified Claudespaces.Container as Container
import qualified Claudespaces.HostServer as HostServer
import qualified Claudespaces.Workspaces as Workspaces

healStaleWorkspaces :: App ()
healStaleWorkspaces = do
  sf <- asks (.stateFile)
  runningIds <- liftIO Container.getRunningContainerIds
  liftIO $ Workspaces.healRunning sf runningIds

ensureBridge :: Int -> IO ()
ensureBridge port = do
  running <- HostServer.isRunning port
  if running then pure () else HostServer.startServer

attachWithCleanup :: Text -> Text -> Int -> App ()
attachWithCleanup wsName containerId port = do
  sf <- asks (.stateFile)
  liftIO $ do
    ensureBridge port
    Workspaces.updateWorkspace sf wsName (\w -> w { Workspaces.status = Workspaces.Running })
    Container.attachContainer containerId
      `finally` do
        now <- nowUtc
        Workspaces.updateWorkspace sf wsName (\w -> w
          { Workspaces.status     = Workspaces.Stopped
          , Workspaces.lastUsedAt = now
          })
        Container.stopContainer containerId
        HostServer.stopServerIfLast wsName sf
  where
    nowUtc = do
      t <- Data.Time.Clock.getCurrentTime
      pure $ T.pack $ Data.Time.Format.ISO8601.iso8601Show t
```

Note: the `nowUtc` helper and necessary time imports need to be added. Import `Data.Time.Clock (getCurrentTime)` and `Data.Time.Format.ISO8601 (iso8601Show)`.

- [ ] **Step 2: Refactor Cli.hs to use App monad and Lifecycle**

Key changes:
- `run` wraps dispatch in `mkEnv` + `runReaderT` + top-level `catch`:
  ```haskell
  run :: IO ()
  run = do
    cmd <- execParser opts
    env <- mkEnv
    runReaderT (dispatch cmd) env
      `catch` \(e :: AppError) -> do
        hPutStrLn stderr $ displayError e
        exitFailure
  ```
- Each `cmd*` function becomes `App ()` instead of `IO ()`
- Replace `sf <- Workspaces.defaultStateFile` with `sf <- asks (.stateFile)`
- Replace `home <- getHomeDirectory` with `home <- asks (.home)`
- Replace `gcPath <- globalConfigPath` with `gcPath <- asks (.globalConfigPath)`
- Replace `shimsPath <- HostConfig.defaultShimsPath` with `shimsPath <- asks (.shimsPath)`
- Replace `exitFailure` error patterns with `throwIO` of appropriate `AppError` constructors
- The attach+cleanup blocks in `cmdNew` and `cmdStart` call `attachWithCleanup` from `Lifecycle`
- The heal+running-ids pattern calls `healStaleWorkspaces` from `Lifecycle`
- Remove `checkDocker` local function; replace with `unless`/`throwIO DockerNotReachable`
- All workspace field access uses dot syntax
- Remove duplicate `sortBy` definition; use `Data.List.sortBy`

- [ ] **Step 3: Add Lifecycle to exposed-modules in package.yaml**

- [ ] **Step 4: Verify it builds and all tests pass**

Run: `stack build && stack test`

Expected: 72 tests pass. The test suite doesn't test Cli.hs directly so this verifies compilation and that all downstream modules still work.

- [ ] **Step 5: Commit**

```bash
git add src/Claudespaces/Lifecycle.hs src/Claudespaces/Cli.hs package.yaml
git commit -m "refactor: extract Lifecycle module, Cli uses App monad with top-level error handler"
```

---

### Task 11: Final verification

- [ ] **Step 1: Run full test suite**

Run: `stack test`

Expected: all tests pass.

- [ ] **Step 2: Verify CLI still works**

```bash
stack exec claudespaces -- --help
stack exec claudespaces -- list
```

Expected: same output as before the refactor.

- [ ] **Step 3: Check for any remaining `userError` or `ioError` calls**

Run: `grep -rn 'userError\|ioError' src/`

Expected: no hits (all replaced with `AppError`).

- [ ] **Step 4: Check for any remaining prefixed field access**

Run: `grep -rn 'wsName\|wsStatus\|wsDirs\|wsContainerId\|wsImage\|wsCreatedAt\|wsLastUsedAt\|cfgImage\|cfgDockerfile\|cfgGlobal\|cfgDirectories\|cfgAdditional\|opCommand\|opArgs\|opAsync\|opOverride\|bridgePort\|bridgeOp\|mSource\|mTarget\|mReadOnly\|mountSource\|mountTarget\|mountReadOnly' src/`

Expected: no hits in source (tests may still have some in string literals or JSON field names, which is fine).

- [ ] **Step 5: Commit any final fixes**

```bash
git add -A
git commit -m "chore: final cleanup after idiomatic pass"
```
