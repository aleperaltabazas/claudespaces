# Idiomatic Haskell Second Pass — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor the claudespaces Haskell codebase from a Python transliteration into idiomatic Haskell — better types, cleaner error handling, ReaderT-based config threading, and dot-syntax record access.

**Architecture:** Bottom-up: create leaf modules (Error, Env) first, then refactor existing modules one at a time against new types, then extract Lifecycle from Cli. Each task produces a compiling + passing codebase.

**Tech Stack:** Haskell, Stack (LTS-23.18, GHC 9.8), Hspec, Hedgehog, mtl, aeson, scotty, optparse-applicative

---

## File Map

| Action | File | Responsibility |
|--------|------|----------------|
| Create | `src/Claudespaces/Error.hs` | `AppError` sum type + `Exception` instance + `displayError` |
| Create | `src/Claudespaces/Env.hs` | `Env` record + `App` type alias + `mkEnv` |
| Create | `src/Claudespaces/Lifecycle.hs` | Shared orchestration: attach/cleanup, heal, bridge |
| Create | `src/Claudespaces/Workspaces/Internal.hs` | Word lists (`adjectives`, `nouns`) |
| Modify | `package.yaml` | Add `mtl` dep, `default-extensions`, new exposed modules |
| Modify | `src/Claudespaces/Config.hs` | `Mount` type (merged), drop prefixes, `AppError`, idioms |
| Modify | `src/Claudespaces/Workspaces.hs` | `Status` ADT, drop prefixes, re-export from Internal |
| Modify | `src/Claudespaces/Container.hs` | Drop `MountSpec`, use `Mount`, pure `checkBasenameCollision` |
| Modify | `src/Claudespaces/Image.hs` | `AppError`, idioms |
| Modify | `src/Claudespaces/HostConfig.hs` | Drop prefixes, idioms |
| Modify | `src/Claudespaces/HostServer.hs` | Dot syntax, idioms |
| Modify | `src/Claudespaces/Cli.hs` | `App` monad, extract lifecycle, top-level error handler |
| Modify | `test/Claudespaces/ConfigSpec.hs` | `Mount`, unprefixed fields |
| Modify | `test/Claudespaces/ContainerSpec.hs` | `Mount`, pure collision check |
| Modify | `test/Claudespaces/WorkspacesSpec.hs` | `Status` ADT, unprefixed fields, Internal import |
| Modify | `test/Claudespaces/HostConfigSpec.hs` | Dot syntax field access |
| Modify | `test/Claudespaces/ImageSpec.hs` | No structural changes (already clean) |

---

### Task 1: Project config — extensions, dependencies, exposed modules

**Files:**
- Modify: `package.yaml`

- [ ] **Step 1: Add default-extensions and mtl dependency**

In `package.yaml`, add `mtl` to the top-level `dependencies`:

```yaml
dependencies:
  - base >= 4.7 && < 5
  - aeson
  - containers
  - bytestring
  - cryptohash-md5
  - directory
  - file-embed
  - filepath
  - http-types
  - mtl
  - network
  - optparse-applicative
  - process
  - random
  - scotty
  - text
  - text-conversions
  - vector
  - time
  - unix
  - yaml
```

Add `default-extensions` at the top level (applies to library, executables, and tests):

```yaml
default-extensions:
  - DuplicateRecordFields
  - OverloadedRecordDot
  - OverloadedStrings
  - ScopedTypeVariables
```

- [ ] **Step 2: Add new exposed modules**

Add to the `exposed-modules` list in `library`:

```yaml
  exposed-modules:
    - Claudespaces.Cli
    - Claudespaces.Config
    - Claudespaces.Container
    - Claudespaces.Env
    - Claudespaces.Error
    - Claudespaces.HostConfig
    - Claudespaces.HostServer
    - Claudespaces.Image
    - Claudespaces.Lifecycle
    - Claudespaces.Workspaces
    - Claudespaces.Workspaces.Internal
```

- [ ] **Step 3: Create module stubs so the build passes**

Create `src/Claudespaces/Error.hs`:
```haskell
module Claudespaces.Error where
```

Create `src/Claudespaces/Env.hs`:
```haskell
module Claudespaces.Env where
```

Create `src/Claudespaces/Lifecycle.hs`:
```haskell
module Claudespaces.Lifecycle where
```

Create `src/Claudespaces/Workspaces/Internal.hs`:
```haskell
module Claudespaces.Workspaces.Internal where
```

- [ ] **Step 4: Remove per-file language pragmas that are now global**

Remove `{-# LANGUAGE OverloadedStrings #-}` from all source files:
- `src/Claudespaces/Config.hs`
- `src/Claudespaces/Container.hs`
- `src/Claudespaces/HostConfig.hs`
- `src/Claudespaces/HostServer.hs`
- `src/Claudespaces/Image.hs`
- `src/Claudespaces/Workspaces.hs`
- `src/Claudespaces/Cli.hs`

Remove `{-# LANGUAGE ScopedTypeVariables #-}` from:
- `src/Claudespaces/HostServer.hs`
- `src/Claudespaces/Cli.hs`

Remove `{-# LANGUAGE OverloadedStrings #-}` from all test files:
- `test/Claudespaces/ConfigSpec.hs`
- `test/Claudespaces/ContainerSpec.hs`
- `test/Claudespaces/HostConfigSpec.hs`
- `test/Claudespaces/ImageSpec.hs`
- `test/Claudespaces/WorkspacesSpec.hs`

- [ ] **Step 5: Build and test**

Run: `stack build && stack test 2>&1 | tail -20`
Expected: BUILD SUCCEEDED, all tests pass

- [ ] **Step 6: Commit**

```bash
git add package.yaml src/Claudespaces/Error.hs src/Claudespaces/Env.hs src/Claudespaces/Lifecycle.hs src/Claudespaces/Workspaces/Internal.hs src/Claudespaces/*.hs test/Claudespaces/*.hs
git commit -m "chore: promote language extensions to default-extensions, add mtl

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 2: Error module

**Files:**
- Modify: `src/Claudespaces/Error.hs`

- [ ] **Step 1: Implement the AppError type**

Replace the stub with the full module:

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
displayError (ConfigError msg)              = "Config error: " <> T.unpack msg
displayError (WorkspaceNotFound name)       = "Workspace '" <> T.unpack name <> "' not found"
displayError (WorkspaceAlreadyExists name)  = "Workspace '" <> T.unpack name <> "' already exists"
displayError (WorkspaceAlreadyRunning name) = "Workspace '" <> T.unpack name <> "' is already running"
displayError (WorkspaceAlreadyStopped name) = "Workspace '" <> T.unpack name <> "' is already stopped"
displayError DockerNotReachable             = "Docker is not reachable. Is the daemon running?"
displayError (DockerBuildFailed msg)        = "Docker build failed: " <> T.unpack msg
displayError (DockerfileNotFound path)      = "Dockerfile not found: " <> path
displayError (BasenameCollision name)       = "Basename collision: multiple directories share the basename '" <> name <> "'"
displayError (MountOverlap targets)         = "Overlapping container mount targets between global and local config: " <> T.unpack (T.intercalate ", " targets)
displayError (InvalidMount msg)             = "Invalid mount: " <> T.unpack msg
displayError NameGenerationFailed           = "Could not generate a unique workspace name"
displayError HomeNotSet                     = "HOME environment variable not set"
```

- [ ] **Step 2: Build**

Run: `stack build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add src/Claudespaces/Error.hs
git commit -m "feat: add Error module with AppError type and displayError

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 3: Env module

**Files:**
- Modify: `src/Claudespaces/Env.hs`

- [ ] **Step 1: Implement Env, App, and mkEnv**

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

- [ ] **Step 2: Build**

Run: `stack build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add src/Claudespaces/Env.hs
git commit -m "feat: add Env module for idiomatic refactoring

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 4: Config module — Mount type, drop prefixes, AppError

**Files:**
- Modify: `src/Claudespaces/Config.hs`
- Modify: `test/Claudespaces/ConfigSpec.hs`

- [ ] **Step 1: Rewrite Config.hs**

```haskell
module Claudespaces.Config
  ( Config (..)
  , Mount (..)
  , emptyConfig
  , loadConfig
  , parseMount
  ) where

import Control.Exception     (throwIO)
import Data.List             (nub)
import Data.Maybe            (fromMaybe)
import qualified Data.Set    as Set
import Data.Text             (Text)
import qualified Data.Text   as T
import Data.Yaml             (FromJSON (..), decodeThrow, withObject, (.:?))
import qualified Data.ByteString as BS
import System.Directory      (doesFileExist)
import System.FilePath       ((</>))

import Claudespaces.Error    (AppError (..))

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
emptyConfig = Config
  { image            = Nothing
  , dockerfile       = Nothing
  , globalDockerfile = Nothing
  , directories      = []
  , additionalMounts = []
  }

-- Internal raw config (parsed directly from YAML)

data RawConfig = RawConfig
  { image            :: Maybe Text
  , dockerfile       :: Maybe Text
  , directories      :: [Text]
  , additionalMounts :: [Text]
  } deriving (Eq, Show)

emptyRaw :: RawConfig
emptyRaw = RawConfig Nothing Nothing [] []

instance FromJSON RawConfig where
  parseJSON = withObject "RawConfig" $ \o -> do
    img    <- o .:? "image"
    df     <- o .:? "dockerfile"
    dirs   <- o .:? "directories"
    mounts <- o .:? "additional-mounts"
    pure RawConfig
      { image            = img
      , dockerfile       = df
      , directories      = fromMaybe [] dirs
      , additionalMounts = fromMaybe [] mounts
      }

parseMount :: Text -> Either AppError Mount
parseMount raw =
  case T.splitOn ":" raw of
    [src, dst]       -> Right $ Mount src dst False
    [src, dst, mode] -> case mode of
      "ro" -> Right $ Mount src dst True
      "rw" -> Right $ Mount src dst False
      _    -> Left $ InvalidMount $ "Invalid mount mode: " <> mode
    _ -> Left $ InvalidMount $ "Invalid mount entry (expected src:dst or src:dst:ro|rw): " <> raw

-- Internal helpers

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

validate :: String -> RawConfig -> Either AppError ()
validate label rc =
  case (rc.image, rc.dockerfile) of
    (Just _, Just _) -> Left $ ConfigError $ T.pack $
      label <> ": cannot specify both 'image' and 'dockerfile'"
    _ -> Right ()

parseMounts :: [Text] -> Either AppError [Mount]
parseMounts = traverse parseMount

checkOverlap :: [Mount] -> [Mount] -> Either AppError ()
checkOverlap globalMounts localMounts =
  let globalTargets = Set.fromList (map (.target) globalMounts)
      localTargets  = Set.fromList (map (.target) localMounts)
      overlap       = Set.intersection globalTargets localTargets
  in if Set.null overlap
       then Right ()
       else Left $ MountOverlap (Set.toList overlap)

loadConfig :: FilePath -> FilePath -> IO Config
loadConfig cwd globalPath = do
  global <- loadYaml globalPath
  local  <- loadYaml (cwd </> "claudespaces.yml")

  either throwIO pure $ validate "global config" global
  either throwIO pure $ validate "local config"  local

  globalMnts <- either throwIO pure $ parseMounts global.additionalMounts
  localMnts  <- either throwIO pure $ parseMounts local.additionalMounts

  either throwIO pure $ checkOverlap globalMnts localMnts

  let mergedImage = local.image <|> global.image
  let mergedDirs  = nub (global.directories ++ local.directories)
  let mergedMnts  = globalMnts ++ localMnts

  pure Config
    { image            = mergedImage
    , dockerfile       = local.dockerfile
    , globalDockerfile = global.dockerfile
    , directories      = mergedDirs
    , additionalMounts = mergedMnts
    }
```

Note: `<|>` for `Maybe` is re-exported from `Prelude` in GHC 9.8. If it's not in scope, add `import Control.Applicative ((<|>))`.

- [ ] **Step 2: Update ConfigSpec.hs**

```haskell
module Claudespaces.ConfigSpec (spec) where

import Claudespaces.Config
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = do
  describe "parseMount" $ do
    it "parses src:dst as rw" $
      parseMount "/host/path:/container/path"
        `shouldBe` Right (Mount "/host/path" "/container/path" False)

    it "parses src:dst:rw" $
      parseMount "/host/path:/container/path:rw"
        `shouldBe` Right (Mount "/host/path" "/container/path" False)

    it "parses src:dst:ro" $
      parseMount "/host/path:/container/path:ro"
        `shouldBe` Right (Mount "/host/path" "/container/path" True)

    it "rejects single-part entry" $
      parseMount "/only-one-part" `shouldSatisfy` isLeft

    it "rejects invalid mode" $
      parseMount "/host/path:/container/path:rw2" `shouldSatisfy` isLeft

  describe "loadConfig" $ do
    it "returns empty config when no files exist" $
      withSystemTempDirectory "cfg" $ \dir -> do
        cfg <- loadConfig dir (dir </> "nonexistent-global.yaml")
        cfg `shouldBe` emptyConfig

    it "parses image key from local config" $
      withSystemTempDirectory "cfg" $ \dir -> do
        writeFile (dir </> "claudespaces.yml") "image: ubuntu:24.04\n"
        cfg <- loadConfig dir (dir </> "nope.yaml")
        cfg.image `shouldBe` Just "ubuntu:24.04"

    it "parses dockerfile key from local config" $
      withSystemTempDirectory "cfg" $ \dir -> do
        writeFile (dir </> "claudespaces.yml") "dockerfile: ./Dockerfile\n"
        cfg <- loadConfig dir (dir </> "nope.yaml")
        cfg.dockerfile `shouldBe` Just "./Dockerfile"

    it "raises on both image and dockerfile in local" $
      withSystemTempDirectory "cfg" $ \dir -> do
        writeFile (dir </> "claudespaces.yml") "image: foo\ndockerfile: ./Dockerfile\n"
        loadConfig dir (dir </> "nope.yaml") `shouldThrow` anyException

    it "parses directories from local config" $
      withSystemTempDirectory "cfg" $ \dir -> do
        writeFile (dir </> "claudespaces.yml") "directories:\n  - ~/proj1\n  - ~/proj2\n"
        cfg <- loadConfig dir (dir </> "nope.yaml")
        cfg.directories `shouldBe` ["~/proj1", "~/proj2"]

    it "returns empty config for empty yaml file" $
      withSystemTempDirectory "cfg" $ \dir -> do
        writeFile (dir </> "claudespaces.yml") ""
        cfg <- loadConfig dir (dir </> "nope.yaml")
        cfg `shouldBe` emptyConfig

    it "exposes global dockerfile as globalDockerfile" $
      withSystemTempDirectory "cfg" $ \dir -> do
        writeFile (dir </> "global.yaml") "dockerfile: ~/.config/claudespaces/Dockerfile\n"
        cfg <- loadConfig dir (dir </> "global.yaml")
        cfg.globalDockerfile `shouldBe` Just "~/.config/claudespaces/Dockerfile"
        cfg.dockerfile `shouldBe` Nothing

    it "raises on both image and dockerfile in global" $
      withSystemTempDirectory "cfg" $ \dir -> do
        writeFile (dir </> "global.yaml") "image: foo\ndockerfile: ./Dockerfile\n"
        loadConfig dir (dir </> "global.yaml") `shouldThrow` anyException

    it "local image overrides global image" $
      withSystemTempDirectory "cfg" $ \dir -> do
        writeFile (dir </> "global.yaml") "image: ubuntu:24.04\n"
        writeFile (dir </> "claudespaces.yml") "image: debian:12\n"
        cfg <- loadConfig dir (dir </> "global.yaml")
        cfg.image `shouldBe` Just "debian:12"

    it "uses global image when no local image" $
      withSystemTempDirectory "cfg" $ \dir -> do
        writeFile (dir </> "global.yaml") "image: debian:12\n"
        cfg <- loadConfig dir (dir </> "global.yaml")
        cfg.image `shouldBe` Just "debian:12"

    it "keeps both global dockerfile and local dockerfile" $
      withSystemTempDirectory "cfg" $ \dir -> do
        writeFile (dir </> "global.yaml") "dockerfile: ~/.config/claudespaces/Dockerfile\n"
        writeFile (dir </> "claudespaces.yml") "dockerfile: ./Dockerfile\n"
        cfg <- loadConfig dir (dir </> "global.yaml")
        cfg.globalDockerfile `shouldBe` Just "~/.config/claudespaces/Dockerfile"
        cfg.dockerfile `shouldBe` Just "./Dockerfile"

    it "keeps global dockerfile and local image" $
      withSystemTempDirectory "cfg" $ \dir -> do
        writeFile (dir </> "global.yaml") "dockerfile: ~/.config/claudespaces/Dockerfile\n"
        writeFile (dir </> "claudespaces.yml") "image: debian:12\n"
        cfg <- loadConfig dir (dir </> "global.yaml")
        cfg.globalDockerfile `shouldBe` Just "~/.config/claudespaces/Dockerfile"
        cfg.image `shouldBe` Just "debian:12"

    it "merges directories from global and local" $
      withSystemTempDirectory "cfg" $ \dir -> do
        writeFile (dir </> "global.yaml") "directories:\n  - ~/global-proj\n"
        writeFile (dir </> "claudespaces.yml") "directories:\n  - ~/local-proj\n"
        cfg <- loadConfig dir (dir </> "global.yaml")
        cfg.directories `shouldBe` ["~/global-proj", "~/local-proj"]

  describe "additional mounts" $ do
    it "parses local additional-mounts" $
      withSystemTempDirectory "cfg" $ \dir -> do
        writeFile (dir </> "claudespaces.yml") "additional-mounts:\n  - /src:/dst:ro\n"
        cfg <- loadConfig dir (dir </> "nope.yaml")
        cfg.additionalMounts `shouldBe` [Mount "/src" "/dst" True]

    it "parses global additional-mounts" $
      withSystemTempDirectory "cfg" $ \dir -> do
        writeFile (dir </> "global.yaml") "additional-mounts:\n  - /g:/cg:rw\n"
        cfg <- loadConfig dir (dir </> "global.yaml")
        cfg.additionalMounts `shouldBe` [Mount "/g" "/cg" False]

    it "merges global and local additional-mounts" $
      withSystemTempDirectory "cfg" $ \dir -> do
        writeFile (dir </> "global.yaml") "additional-mounts:\n  - /g:/cg\n"
        writeFile (dir </> "claudespaces.yml") "additional-mounts:\n  - /l:/cl:ro\n"
        cfg <- loadConfig dir (dir </> "global.yaml")
        cfg.additionalMounts
          `shouldBe` [ Mount "/g" "/cg" False
                     , Mount "/l" "/cl" True
                     ]

    it "raises on overlapping container targets" $
      withSystemTempDirectory "cfg" $ \dir -> do
        writeFile (dir </> "global.yaml") "additional-mounts:\n  - /g:/shared\n"
        writeFile (dir </> "claudespaces.yml") "additional-mounts:\n  - /l:/shared\n"
        loadConfig dir (dir </> "global.yaml") `shouldThrow` anyException

    it "omits additional_mounts when none defined" $
      withSystemTempDirectory "cfg" $ \dir -> do
        cfg <- loadConfig dir (dir </> "nope.yaml")
        cfg.additionalMounts `shouldBe` []

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft _        = False
```

- [ ] **Step 3: Build and test**

Run: `stack build && stack test --test-arguments '--match Config' 2>&1 | tail -20`
Expected: All Config tests pass

- [ ] **Step 4: Commit**

```bash
git add src/Claudespaces/Config.hs test/Claudespaces/ConfigSpec.hs
git commit -m "refactor: Config uses Mount, AppError, dot syntax, drop prefixes

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 5: Workspaces module — Status ADT, drop prefixes, Internal

**Files:**
- Modify: `src/Claudespaces/Workspaces.hs`
- Modify: `src/Claudespaces/Workspaces/Internal.hs`
- Modify: `test/Claudespaces/WorkspacesSpec.hs`

- [ ] **Step 1: Populate Workspaces.Internal with word lists**

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

- [ ] **Step 2: Rewrite Workspaces.hs**

```haskell
module Claudespaces.Workspaces
  ( Workspace (..)
  , Status (..)
  , allWorkspaces
  , getByName
  , nameExists
  , saveWorkspace
  , updateWorkspace
  , removeWorkspace
  , healRunning
  , generateName
  , stateDir
  , defaultStateFile
  ) where

import Control.Exception       (throwIO)
import Data.Aeson              (FromJSON (..), ToJSON (..), Value (..),
                                object, withObject, withText, (.:), (.=))
import qualified Data.Aeson    as Aeson
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Aeson.Key as Key
import qualified Data.ByteString.Lazy as BL
import Data.Maybe              (isJust)
import Data.Set                (Set)
import qualified Data.Set      as Set
import Data.Text               (Text)
import qualified Data.Text     as T
import System.Directory        (createDirectoryIfMissing, doesFileExist)
import System.Environment      (lookupEnv)
import System.FilePath         (takeDirectory, (</>))
import System.Random           (randomRIO)

import Claudespaces.Error      (AppError (..))
import Claudespaces.Workspaces.Internal (adjectives, nouns)

data Status = Running | Stopped
  deriving (Eq, Show)

instance FromJSON Status where
  parseJSON = withText "Status" $ \t -> case t of
    "running" -> pure Running
    "stopped" -> pure Stopped
    _         -> fail $ "Unknown status: " <> T.unpack t

instance ToJSON Status where
  toJSON Running = Aeson.String "running"
  toJSON Stopped = Aeson.String "stopped"

data Workspace = Workspace
  { name        :: Text
  , dirs        :: [Text]
  , containerId :: Text
  , image       :: Text
  , createdAt   :: Text
  , lastUsedAt  :: Text
  , status      :: Status
  } deriving (Eq, Show)

instance FromJSON Workspace where
  parseJSON = withObject "Workspace" $ \o ->
    Workspace
      <$> o .: "name"
      <*> o .: "dirs"
      <*> o .: "container_id"
      <*> o .: "image"
      <*> o .: "created_at"
      <*> o .: "last_used_at"
      <*> o .: "status"

instance ToJSON Workspace where
  toJSON ws = object
    [ "name"         .= ws.name
    , "dirs"         .= ws.dirs
    , "container_id" .= ws.containerId
    , "image"        .= ws.image
    , "created_at"   .= ws.createdAt
    , "last_used_at" .= ws.lastUsedAt
    , "status"       .= ws.status
    ]

-- Internal helpers

load :: FilePath -> IO [Workspace]
load path = do
  exists <- doesFileExist path
  if exists
    then do
      bs <- BL.readFile path
      case Aeson.eitherDecode bs of
        Right ws -> pure ws
        Left err -> throwIO $ ConfigError $ T.pack $
          "Failed to parse " <> path <> ": " <> err
    else do
      migrated <- tryMigrate path
      pure $ maybe [] id migrated

tryMigrate :: FilePath -> IO (Maybe [Workspace])
tryMigrate statePath = do
  let sessionsPath = takeDirectory statePath </> "sessions.json"
  exists <- doesFileExist sessionsPath
  if not exists
    then pure Nothing
    else do
      bs <- BL.readFile sessionsPath
      case Aeson.eitherDecode bs :: Either String [Value] of
        Left _     -> pure Nothing
        Right vals -> do
          let stripped = map dropId vals
          case mapM Aeson.fromJSON stripped of
            Aeson.Error _    -> pure Nothing
            Aeson.Success ws -> do
              save statePath ws
              pure (Just ws)

dropId :: Value -> Value
dropId (Object o) = Object (KM.delete (Key.fromString "id") o)
dropId v          = v

save :: FilePath -> [Workspace] -> IO ()
save path ws = do
  createDirectoryIfMissing True (takeDirectory path)
  BL.writeFile path (Aeson.encode ws)

-- Public API

allWorkspaces :: FilePath -> IO [Workspace]
allWorkspaces = load

getByName :: FilePath -> Text -> IO (Maybe Workspace)
getByName path wsName = do
  ws <- load path
  pure $ case filter (\w -> w.name == wsName) ws of
    (x:_) -> Just x
    []    -> Nothing

nameExists :: FilePath -> Text -> IO Bool
nameExists path wsName = isJust <$> getByName path wsName

saveWorkspace :: FilePath -> Workspace -> IO ()
saveWorkspace path ws = do
  existing <- load path
  save path (existing ++ [ws])

updateWorkspace :: FilePath -> Text -> (Workspace -> Workspace) -> IO ()
updateWorkspace path wsName f = do
  ws <- load path
  let (matched, others) = foldr partition' ([], []) ws
  case matched of
    []    -> throwIO $ WorkspaceNotFound wsName
    (x:_) -> save path (others ++ [f x])
  where
    partition' w (ms, os)
      | w.name == wsName = (w : ms, os)
      | otherwise        = (ms, w : os)

removeWorkspace :: FilePath -> Text -> IO ()
removeWorkspace path wsName = do
  ws <- load path
  save path (filter (\w -> w.name /= wsName) ws)

healRunning :: FilePath -> Set Text -> IO ()
healRunning path running = do
  ws <- load path
  save path (map heal ws)
  where
    heal w
      | w.status == Running && not (Set.member w.containerId running) =
          w { status = Stopped }
      | otherwise = w

generateName :: Set Text -> IO Text
generateName taken = go (10000 :: Int)
  where
    go 0 = throwIO NameGenerationFailed
    go n = do
      ai <- randomRIO (0, length adjectives - 1)
      ni <- randomRIO (0, length nouns - 1)
      let candidate = (adjectives !! ai) <> "-" <> (nouns !! ni)
      if Set.member candidate taken
        then go (n - 1)
        else pure candidate

stateDir :: FilePath -> Text -> FilePath
stateDir base sub = takeDirectory base </> T.unpack sub

defaultStateFile :: IO FilePath
defaultStateFile = do
  mHome <- lookupEnv "HOME"
  case mHome of
    Just h  -> pure $ h </> ".claudespaces" </> "workspaces.json"
    Nothing -> throwIO HomeNotSet
```

- [ ] **Step 3: Update WorkspacesSpec.hs**

```haskell
module Claudespaces.WorkspacesSpec (spec) where

import Test.Hspec
import System.IO.Temp        (withSystemTempDirectory)
import System.FilePath        ((</>))
import Data.Text              (Text)
import qualified Data.Text    as T
import qualified Data.Set     as Set

import Claudespaces.Workspaces
import Claudespaces.Workspaces.Internal (adjectives, nouns)

sampleWorkspace :: Text -> Workspace
sampleWorkspace n = Workspace
  { name        = n
  , dirs        = ["/home/user/proj"]
  , containerId = "abc123"
  , image       = "ubuntu:24.04"
  , createdAt   = "2024-01-01T00:00:00"
  , lastUsedAt  = "2024-01-01T00:00:00"
  , status      = Stopped
  }

spec :: Spec
spec = do
  describe "saveWorkspace / allWorkspaces" $ do
    it "saves and reads back a single workspace" $
      withSystemTempDirectory "ws" $ \dir -> do
        let f = dir </> "workspaces.json"
        let ws = sampleWorkspace "bold-comet"
        saveWorkspace f ws
        result <- allWorkspaces f
        result `shouldBe` [ws]

    it "allWorkspaces returns all saved workspaces" $
      withSystemTempDirectory "ws" $ \dir -> do
        let f = dir </> "workspaces.json"
        saveWorkspace f (sampleWorkspace "bold-comet")
        saveWorkspace f (sampleWorkspace "calm-river")
        result <- allWorkspaces f
        length result `shouldBe` 2

    it "multiple workspaces for the same dirs are allowed" $
      withSystemTempDirectory "ws" $ \dir -> do
        let f = dir </> "workspaces.json"
        let ws1 = (sampleWorkspace "bold-comet") { dirs = ["/home/user/proj"] }
        let ws2 = (sampleWorkspace "calm-river")  { dirs = ["/home/user/proj"] }
        saveWorkspace f ws1
        saveWorkspace f ws2
        result <- allWorkspaces f
        length result `shouldBe` 2

  describe "getByName" $ do
    it "finds a workspace by name" $
      withSystemTempDirectory "ws" $ \dir -> do
        let f = dir </> "workspaces.json"
        let ws = sampleWorkspace "bold-comet"
        saveWorkspace f ws
        result <- getByName f "bold-comet"
        result `shouldBe` Just ws

    it "returns Nothing when name not found" $
      withSystemTempDirectory "ws" $ \dir -> do
        let f = dir </> "workspaces.json"
        saveWorkspace f (sampleWorkspace "bold-comet")
        result <- getByName f "no-such-name"
        result `shouldBe` Nothing

  describe "nameExists" $ do
    it "returns True when name exists" $
      withSystemTempDirectory "ws" $ \dir -> do
        let f = dir </> "workspaces.json"
        saveWorkspace f (sampleWorkspace "bold-comet")
        nameExists f "bold-comet" `shouldReturn` True

    it "returns False when name does not exist" $
      withSystemTempDirectory "ws" $ \dir -> do
        let f = dir </> "workspaces.json"
        saveWorkspace f (sampleWorkspace "bold-comet")
        nameExists f "no-such-name" `shouldReturn` False

  describe "updateWorkspace" $ do
    it "changes specified fields" $
      withSystemTempDirectory "ws" $ \dir -> do
        let f = dir </> "workspaces.json"
        saveWorkspace f (sampleWorkspace "bold-comet")
        updateWorkspace f "bold-comet" (\ws -> ws { status = Running })
        result <- getByName f "bold-comet"
        fmap (.status) result `shouldBe` Just Running

    it "leaves other fields intact" $
      withSystemTempDirectory "ws" $ \dir -> do
        let f = dir </> "workspaces.json"
        saveWorkspace f (sampleWorkspace "bold-comet")
        updateWorkspace f "bold-comet" (\ws -> ws { status = Running })
        result <- getByName f "bold-comet"
        fmap (.image) result `shouldBe` Just "ubuntu:24.04"
        fmap (.dirs)  result `shouldBe` Just ["/home/user/proj"]

    it "raises when name not found" $
      withSystemTempDirectory "ws" $ \dir -> do
        let f = dir </> "workspaces.json"
        updateWorkspace f "no-such-name" id `shouldThrow` anyException

  describe "removeWorkspace" $ do
    it "removes the correct record" $
      withSystemTempDirectory "ws" $ \dir -> do
        let f = dir </> "workspaces.json"
        saveWorkspace f (sampleWorkspace "bold-comet")
        saveWorkspace f (sampleWorkspace "calm-river")
        removeWorkspace f "bold-comet"
        result <- allWorkspaces f
        map (.name) result `shouldBe` ["calm-river"]

  describe "healRunning" $ do
    it "marks stale running workspaces as stopped" $
      withSystemTempDirectory "ws" $ \dir -> do
        let f = dir </> "workspaces.json"
        let ws = (sampleWorkspace "bold-comet") { status = Running, containerId = "stale123" }
        saveWorkspace f ws
        healRunning f (Set.fromList [])
        result <- getByName f "bold-comet"
        fmap (.status) result `shouldBe` Just Stopped

    it "leaves actually running workspaces unchanged" $
      withSystemTempDirectory "ws" $ \dir -> do
        let f = dir </> "workspaces.json"
        let ws = (sampleWorkspace "bold-comet") { status = Running, containerId = "live123" }
        saveWorkspace f ws
        healRunning f (Set.fromList ["live123"])
        result <- getByName f "bold-comet"
        fmap (.status) result `shouldBe` Just Running

    it "leaves stopped workspaces unchanged" $
      withSystemTempDirectory "ws" $ \dir -> do
        let f = dir </> "workspaces.json"
        let ws = (sampleWorkspace "bold-comet") { status = Stopped, containerId = "abc123" }
        saveWorkspace f ws
        healRunning f (Set.fromList [])
        result <- getByName f "bold-comet"
        fmap (.status) result `shouldBe` Just Stopped

    it "only changes stale running, not all" $
      withSystemTempDirectory "ws" $ \dir -> do
        let f = dir </> "workspaces.json"
        let stale   = (sampleWorkspace "bold-comet") { status = Running, containerId = "stale1" }
        let alive   = (sampleWorkspace "calm-river")  { status = Running, containerId = "live1" }
        let stopped = (sampleWorkspace "dark-nova")   { status = Stopped, containerId = "old1" }
        saveWorkspace f stale
        saveWorkspace f alive
        saveWorkspace f stopped
        healRunning f (Set.fromList ["live1"])
        r1 <- getByName f "bold-comet"
        r2 <- getByName f "calm-river"
        r3 <- getByName f "dark-nova"
        fmap (.status) r1 `shouldBe` Just Stopped
        fmap (.status) r2 `shouldBe` Just Running
        fmap (.status) r3 `shouldBe` Just Stopped

  describe "generateName" $ do
    it "produces adjective-noun format" $ do
      n <- generateName Set.empty
      let parts = T.splitOn "-" n
      length parts `shouldBe` 2

    it "avoids collisions by exhausting all but one combo" $ do
      let allCombos = [ adj <> "-" <> noun
                      | adj  <- adjectives
                      , noun <- nouns
                      ]
      let t = head adjectives <> "-" <> head nouns
      let takenSet = Set.fromList (filter (/= t) allCombos)
      n <- generateName takenSet
      n `shouldBe` t

  describe "migration from sessions.json" $ do
    it "migrates sessions.json (drops id field) when workspaces.json absent" $
      withSystemTempDirectory "ws" $ \dir -> do
        let sf = dir </> "workspaces.json"
        let sessionsFile = dir </> "sessions.json"
        writeFile sessionsFile $ unlines
          [ "[{"
          , "  \"id\": \"legacy-id-001\","
          , "  \"name\": \"bold-comet\","
          , "  \"dirs\": [\"/home/user/proj\"],"
          , "  \"container_id\": \"abc123\","
          , "  \"image\": \"ubuntu:24.04\","
          , "  \"created_at\": \"2024-01-01T00:00:00\","
          , "  \"last_used_at\": \"2024-01-01T00:00:00\","
          , "  \"status\": \"stopped\""
          , "}]"
          ]
        result <- allWorkspaces sf
        length result `shouldBe` 1
        (.name) (head result) `shouldBe` "bold-comet"
```

- [ ] **Step 4: Build and test**

Run: `stack build && stack test --test-arguments '--match Workspaces' 2>&1 | tail -20`
Expected: All Workspaces tests pass

- [ ] **Step 5: Commit**

```bash
git add src/Claudespaces/Workspaces.hs src/Claudespaces/Workspaces/Internal.hs test/Claudespaces/WorkspacesSpec.hs
git commit -m "refactor: Workspaces uses Status ADT, dot syntax, Internal module

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 6: Container module — use Mount, pure collision check

**Files:**
- Modify: `src/Claudespaces/Container.hs`
- Modify: `test/Claudespaces/ContainerSpec.hs`

- [ ] **Step 1: Rewrite Container.hs**

```haskell
module Claudespaces.Container
  ( checkBasenameCollision
  , buildMounts
  , hostClaudePaths
  , resolveHostMounts
  , buildEnv
  , mountToArgs
  , createContainer
  , attachContainer
  , getRunningContainerIds
  , stopContainer
  , removeContainer
  ) where

import Control.Monad          (void)
import Data.List              (group, sort)
import Data.Set               (Set)
import qualified Data.Set     as Set
import Data.Text              (Text)
import qualified Data.Text    as T
import System.Directory       (doesFileExist, doesDirectoryExist)
import System.Exit            (ExitCode (..))
import System.FilePath        (takeBaseName, (</>))
import System.Process         (createProcess, proc, readProcess,
                               StdStream (..), std_in, std_out, std_err,
                               delegate_ctlc, waitForProcess)

import Claudespaces.Config    (Mount (..))
import Claudespaces.Error     (AppError (..))

-- Pure functions

checkBasenameCollision :: [FilePath] -> Either AppError ()
checkBasenameCollision dirs' =
  let basenames = map takeBaseName dirs'
      dups = map head . filter ((> 1) . length) . group . sort $ basenames
  in case dups of
    []    -> Right ()
    (d:_) -> Left $ BasenameCollision d

buildMounts :: [FilePath] -> FilePath -> Int -> [Mount] -> FilePath -> [Mount]
buildMounts dirs' sd _hostPort extra homePath =
  userMounts ++ stateMounts ++ hostMounts ++ extra
  where
    userMounts =
      [ Mount
          { source   = T.pack d
          , target   = T.pack $ "/workspace/" <> takeBaseName d
          , readOnly = False
          }
      | d <- dirs'
      ]

    stateMounts =
      [ Mount
          { source   = T.pack (sd </> "claude.json")
          , target   = "/root/.claude.json"
          , readOnly = False
          }
      , Mount
          { source   = T.pack (sd </> "projects")
          , target   = "/root/.claude/projects"
          , readOnly = False
          }
      ]

    hostMounts =
      [ Mount
          { source   = T.pack (homePath </> ".claudespaces" </> "shims.json")
          , target   = "/claudespaces/shims.json"
          , readOnly = True
          }
      ]

hostClaudePaths :: FilePath -> [(FilePath, String)]
hostClaudePaths homePath =
  [ (homePath </> ".claude" </> "settings.json", "/claudespaces/host/settings.json")
  , (homePath </> ".claude" </> "plugins",       "/claudespaces/host/plugins")
  , (homePath </> ".claude" </> "credentials.json", "/claudespaces/host/credentials.json")
  ]

resolveHostMounts :: FilePath -> IO [Mount]
resolveHostMounts homePath = do
  let paths = hostClaudePaths homePath
  concat <$> mapM checkAndMount paths
  where
    checkAndMount (src, tgt) = do
      fileExists <- doesFileExist src
      dirExists  <- doesDirectoryExist src
      if fileExists || dirExists
        then pure [Mount (T.pack src) (T.pack tgt) True]
        else pure []

buildEnv :: Int -> FilePath -> [(String, String)]
buildEnv hostPort homePath =
  [ ("IS_SANDBOX", "1")
  , ("HOST_HOME", homePath)
  , ("CLAUDESPACES_HOST_PORT", show hostPort)
  ]

mountToArgs :: Mount -> [String]
mountToArgs m =
  [ "--mount"
  , "type=bind,source=" ++ T.unpack m.source
      ++ ",target=" ++ T.unpack m.target
      ++ if m.readOnly then ",readonly" else ""
  ]

-- IO wrappers (not tested — thin shell-outs)

createContainer :: Text -> [Mount] -> [(String, String)] -> IO Text
createContainer img mounts envVars = do
  let mountArgs = concatMap mountToArgs mounts
      envArgs   = concatMap (\(k, v) -> ["-e", k <> "=" <> v]) envVars
      args      = [ "create", "--tty", "--interactive"
                  , "--user", "root"
                  , "-w", "/workspace"
                  , "--add-host", "host.docker.internal:host-gateway"
                  ]
                  ++ mountArgs
                  ++ envArgs
                  ++ [T.unpack img]
  T.strip . T.pack <$> readProcess "docker" args ""

attachContainer :: Text -> IO ()
attachContainer cid = do
  let cidStr = T.unpack cid
  void $ readProcess "docker" ["start", cidStr] ""
  (_, _, _, ph) <- createProcess
    (proc "docker"
      [ "exec", "-it"
      , "-e", "TERM=xterm-256color"
      , cidStr
      , "/claudespaces/entrypoint.sh"
      ])
    { std_in  = Inherit
    , std_out = Inherit
    , std_err = Inherit
    , delegate_ctlc = True
    }
  void $ waitForProcess ph

getRunningContainerIds :: IO (Set Text)
getRunningContainerIds = do
  out <- readProcess "docker" ["ps", "-q", "--no-trunc", "--filter", "status=running"] ""
  let ids = filter (not . T.null) . map T.strip . T.lines . T.pack $ out
  pure $ Set.fromList ids

stopContainer :: Text -> IO ()
stopContainer cid =
  void $ readProcess "docker" ["stop", T.unpack cid] ""

removeContainer :: Text -> IO ()
removeContainer cid = do
  (_, _, _, ph) <- createProcess
    (proc "docker" ["rm", "-f", T.unpack cid])
    { std_in  = Inherit
    , std_out = Inherit
    , std_err = Inherit
    }
  void $ waitForProcess ph
```

- [ ] **Step 2: Update ContainerSpec.hs**

```haskell
module Claudespaces.ContainerSpec (spec) where

import Claudespaces.Config (Mount (..))
import Claudespaces.Container
import Data.List (lookup)
import Test.Hspec
import Prelude hiding (lookup)

spec :: Spec
spec = do
  describe "checkBasenameCollision" $ do
    it "returns Left on duplicate basenames" $
      checkBasenameCollision ["/group1/myapp", "/group2/myapp"]
        `shouldSatisfy` isLeft

    it "returns Right for distinct basenames" $
      checkBasenameCollision ["/group1/app", "/group2/web"]
        `shouldBe` Right ()

  describe "buildMounts" $ do
    let sd       = "/state"
        homePath = "/home/user"
        hostPort = 7731
        noExtra  = []

    it "mounts user dir at /workspace/<basename>" $ do
      let mounts = buildMounts ["/home/user/myapp"] sd hostPort noExtra homePath
      let userMount = head mounts
      userMount.target `shouldBe` "/workspace/myapp"

    it "user dir mount is read-write" $ do
      let mounts = buildMounts ["/home/user/myapp"] sd hostPort noExtra homePath
      let userMount = head mounts
      userMount.readOnly `shouldBe` False

    it "mounts state claude.json rw" $ do
      let mounts = buildMounts [] sd hostPort noExtra homePath
      let claudeJson = head mounts
      claudeJson.source `shouldBe` "/state/claude.json"
      claudeJson.target `shouldBe` "/root/.claude.json"
      claudeJson.readOnly `shouldBe` False

    it "mounts state projects rw" $ do
      let mounts = buildMounts [] sd hostPort noExtra homePath
      let projectsMount = mounts !! 1
      projectsMount.source `shouldBe` "/state/projects"
      projectsMount.target `shouldBe` "/root/.claude/projects"
      projectsMount.readOnly `shouldBe` False

    it "mounts shims.json read-only" $ do
      let mounts = buildMounts [] sd hostPort noExtra homePath
      let shimsMount = mounts !! 2
      shimsMount.source `shouldBe` "/home/user/.claudespaces/shims.json"
      shimsMount.target `shouldBe` "/claudespaces/shims.json"
      shimsMount.readOnly `shouldBe` True

    it "appends additional mounts" $ do
      let extra = [Mount "/host/docs" "/docs" True]
      let mounts = buildMounts [] sd hostPort extra homePath
      let lastMount = last mounts
      lastMount.source `shouldBe` "/host/docs"
      lastMount.target `shouldBe` "/docs"
      lastMount.readOnly `shouldBe` True

  describe "buildEnv" $ do
    let env = buildEnv 9999 "/home/user"

    it "includes IS_SANDBOX" $
      lookup "IS_SANDBOX" env `shouldBe` Just "1"

    it "includes HOST_HOME" $
      lookup "HOST_HOME" env `shouldBe` Just "/home/user"

    it "includes CLAUDESPACES_HOST_PORT" $
      lookup "CLAUDESPACES_HOST_PORT" env `shouldBe` Just "9999"

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft _        = False
```

- [ ] **Step 3: Build and test**

Run: `stack build && stack test --test-arguments '--match Container' 2>&1 | tail -20`
Expected: All Container tests pass

- [ ] **Step 4: Commit**

```bash
git add src/Claudespaces/Container.hs test/Claudespaces/ContainerSpec.hs
git commit -m "refactor: Container uses Mount from Config, pure collision check

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 7: Image module — AppError, idioms

**Files:**
- Modify: `src/Claudespaces/Image.hs`

- [ ] **Step 1: Rewrite Image.hs**

```haskell
module Claudespaces.Image
  ( sanitizeTag
  , intermediateTag
  , globalTag
  , customTag
  , imageExists
  , buildImage
  , hashSupportFiles
  , listDirectoryRecursive
  , resolveImage
  ) where

import Control.Exception      (throwIO)
import Control.Monad          (unless)
import Data.List              (sort)
import Data.Maybe             (fromMaybe)
import Data.Text              (Text)
import qualified Data.Text    as T
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BS8
import qualified Crypto.Hash.MD5 as MD5
import System.Directory       (doesFileExist, listDirectory, doesDirectoryExist)
import System.Exit            (ExitCode (..))
import System.FilePath        ((</>))
import System.Process         (readProcessWithExitCode)
import Text.Printf            (printf)

import Claudespaces.Error     (AppError (..))

sanitizeTag :: Text -> Text
sanitizeTag = T.map replace
  where
    replace ':' = '-'
    replace '/' = '-'
    replace c   = c

intermediateTag :: Text -> Text -> Text
intermediateTag baseTag hash =
  "claudespaces-base:" <> sanitizeTag baseTag <> "-" <> hash

globalTag :: FilePath -> Text -> Text
globalTag dockerfilePath baseImage =
  "claudespaces-global:" <> md5Hex12 (dockerfilePath <> ":" <> T.unpack baseImage)

customTag :: FilePath -> Text -> Text
customTag dockerfilePath baseImage =
  "claudespaces-custom:" <> md5Hex12 (dockerfilePath <> ":" <> T.unpack baseImage)

md5Hex12 :: String -> Text
md5Hex12 input =
  T.pack $ take 12 $ concatMap (printf "%02x") $ BS.unpack $ MD5.hash (BS8.pack input)

imageExists :: Text -> IO Bool
imageExists tag = do
  (code, _, _) <- readProcessWithExitCode "docker"
    ["image", "inspect", T.unpack tag] ""
  pure $ code == ExitSuccess

buildImage :: Text -> FilePath -> FilePath -> Text -> IO ()
buildImage tag df context baseImage = do
  (code, _, err) <- readProcessWithExitCode "docker"
    [ "build"
    , "--build-arg", "BASE_IMAGE=" <> T.unpack baseImage
    , "-t", T.unpack tag
    , "-f", df
    , context
    ] ""
  case code of
    ExitSuccess   -> pure ()
    ExitFailure _ -> throwIO $ DockerBuildFailed $ T.pack err

listDirectoryRecursive :: FilePath -> IO [FilePath]
listDirectoryRecursive dir = do
  entries <- listDirectory dir
  let fullPaths = map (dir </>) (sort entries)
  sort . concat <$> mapM expand fullPaths
  where
    expand path = do
      isDir <- doesDirectoryExist path
      if isDir
        then listDirectoryRecursive path
        else pure [path]

hashSupportFiles :: FilePath -> IO Text
hashSupportFiles dir = do
  files    <- listDirectoryRecursive dir
  contents <- mapM BS.readFile files
  let combined = BS.concat contents
  pure $ T.pack $ take 12 $ concatMap (printf "%02x") $ BS.unpack $ MD5.hash combined

resolveImage
  :: Maybe Text
  -> Maybe FilePath
  -> Maybe FilePath
  -> FilePath
  -> IO Text
resolveImage mImage mGlobalDockerfile mDockerfile supportDir = do
  mapM_ checkExists mGlobalDockerfile
  mapM_ checkExists mDockerfile

  let baseImage = fromMaybe "ubuntu:24.04" mImage
  supportHash <- hashSupportFiles supportDir

  afterGlobal <- case mGlobalDockerfile of
    Nothing -> pure baseImage
    Just df -> do
      let tag = globalTag df baseImage
      exists <- imageExists tag
      if exists
        then pure tag
        else do
          buildImage tag df supportDir baseImage
          pure tag

  afterLocal <- case mDockerfile of
    Nothing -> pure afterGlobal
    Just df -> do
      let tag = customTag df afterGlobal
      exists <- imageExists tag
      if exists
        then pure tag
        else do
          buildImage tag df supportDir afterGlobal
          pure tag

  let finalTag = intermediateTag afterLocal supportHash
  exists <- imageExists finalTag
  if exists
    then pure finalTag
    else do
      let claudeDockerfile = supportDir </> "Dockerfile"
      buildImage finalTag claudeDockerfile supportDir afterLocal
      pure finalTag
  where
    checkExists path = do
      ok <- doesFileExist path
      unless ok $ throwIO $ DockerfileNotFound path
```

- [ ] **Step 2: Build and test**

Run: `stack build && stack test --test-arguments '--match Image' 2>&1 | tail -20`
Expected: All Image tests pass (no test changes needed — ImageSpec tests only pure functions)

- [ ] **Step 3: Commit**

```bash
git add src/Claudespaces/Image.hs
git commit -m "refactor: Image uses AppError, fromMaybe, unless

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 8: HostConfig module — drop prefixes, idioms

**Files:**
- Modify: `src/Claudespaces/HostConfig.hs`
- Modify: `test/Claudespaces/HostConfigSpec.hs`

- [ ] **Step 1: Rewrite HostConfig.hs**

```haskell
module Claudespaces.HostConfig
  ( Operation (..)
  , BridgeConfig (..)
  , defaultPort
  , builtinOperations
  , loadHostBridge
  , overridesManifest
  , writeShims
  , defaultShimsPath
  ) where

import Data.Aeson              (FromJSON (..), ToJSON (..), encode,
                                withObject, (.:), (.:?), (.!=))
import qualified Data.Aeson    as Aeson
import qualified Data.ByteString.Lazy as BL
import Data.Map.Strict         (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe              (fromMaybe)
import Data.Text               (Text)
import Data.Yaml               (decodeFileThrow)
import System.Directory        (createDirectoryIfMissing, doesFileExist,
                                getHomeDirectory)
import System.FilePath         ((</>), takeDirectory)

data Operation = Operation
  { command  :: Text
  , args     :: [Text]
  , async    :: Bool
  , override :: Maybe Text
  } deriving (Eq, Show)

data BridgeConfig = BridgeConfig
  { port       :: Int
  , operations :: Map Text Operation
  } deriving (Eq, Show)

defaultPort :: Int
defaultPort = 7731

builtinOperations :: Map Text Operation
builtinOperations = Map.fromList
  [ ("notify", Operation "notify-send {summary} {body}" ["summary", "body"] True (Just "notify-send"))
  ]

instance FromJSON Operation where
  parseJSON = withObject "Operation" $ \o -> do
    cmd       <- o .:  "command"
    args_     <- o .:? "args"     .!= []
    async_    <- o .:? "async"    .!= False
    override_ <- o .:? "override"
    pure $ Operation cmd args_ async_ override_

instance ToJSON Operation where
  toJSON op = Aeson.object
    [ "command"  Aeson..= op.command
    , "args"     Aeson..= op.args
    , "async"    Aeson..= op.async
    , "override" Aeson..= op.override
    ]

-- Internal raw YAML types

data RawBridgeYaml = RawBridgeYaml
  { port       :: Maybe Int
  , operations :: Maybe (Map Text Operation)
  }

instance FromJSON RawBridgeYaml where
  parseJSON = withObject "RawBridgeYaml" $ \o ->
    RawBridgeYaml <$> o .:? "port" <*> o .:? "operations"

newtype RawGlobalYaml = RawGlobalYaml
  { hostBridge :: Maybe RawBridgeYaml
  }

instance FromJSON RawGlobalYaml where
  parseJSON = withObject "RawGlobalYaml" $ \o ->
    RawGlobalYaml <$> o .:? "host_bridge"

loadHostBridge :: FilePath -> IO BridgeConfig
loadHostBridge path = do
  exists <- doesFileExist path
  if not exists
    then pure $ BridgeConfig defaultPort builtinOperations
    else do
      raw <- decodeFileThrow path :: IO RawGlobalYaml
      case raw.hostBridge of
        Nothing     -> pure $ BridgeConfig defaultPort builtinOperations
        Just bridge -> do
          let p       = fromMaybe defaultPort bridge.port
              userOps = fromMaybe Map.empty bridge.operations
              merged  = Map.union userOps builtinOperations
          pure $ BridgeConfig p merged

overridesManifest :: Map Text Operation -> Map Text Text
overridesManifest = Map.foldrWithKey collectOverride Map.empty
  where
    collectOverride opName op acc =
      case op.override of
        Nothing     -> acc
        Just binary -> Map.insert binary opName acc

writeShims :: FilePath -> Map Text Operation -> IO ()
writeShims path ops = do
  createDirectoryIfMissing True (takeDirectory path)
  BL.writeFile path (encode $ overridesManifest ops)

defaultShimsPath :: IO FilePath
defaultShimsPath = do
  h <- getHomeDirectory
  pure $ h </> ".claudespaces" </> "shims.json"
```

- [ ] **Step 2: Update HostConfigSpec.hs**

```haskell
module Claudespaces.HostConfigSpec (spec) where

import Claudespaces.HostConfig
import Data.Aeson (decode)
import qualified Data.ByteString.Lazy as BL
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

writeFile' :: FilePath -> String -> IO ()
writeFile' = writeFile

spec :: Spec
spec = do
  describe "loadHostBridge" $ do
    it "returns default port when no config" $
      withSystemTempDirectory "hc" $ \dir -> do
        cfg <- loadHostBridge (dir </> "nonexistent.yaml")
        cfg.port `shouldBe` 7731

    it "builtin notify always present" $
      withSystemTempDirectory "hc" $ \dir -> do
        cfg <- loadHostBridge (dir </> "nonexistent.yaml")
        Map.member "notify" cfg.operations `shouldBe` True

    it "user config wins on conflict" $
      withSystemTempDirectory "hc" $ \dir -> do
        let cfgFile = dir </> "config.yaml"
        writeFile' cfgFile $
          unlines
            [ "host_bridge:",
              "  operations:",
              "    notify:",
              "      command: 'custom-notify {msg}'",
              "      args: [msg]",
              "      async: true",
              "      override: notify-send"
            ]
        cfg <- loadHostBridge cfgFile
        case Map.lookup "notify" cfg.operations of
          Nothing -> expectationFailure "notify operation not found"
          Just op -> op.command `shouldBe` "custom-notify {msg}"

    it "loads custom port" $
      withSystemTempDirectory "hc" $ \dir -> do
        let cfgFile = dir </> "config.yaml"
        writeFile' cfgFile $
          unlines
            [ "host_bridge:",
              "  port: 9999"
            ]
        cfg <- loadHostBridge cfgFile
        cfg.port `shouldBe` 9999

  describe "overridesManifest" $ do
    it "extracts override operations" $ do
      let ops =
            Map.fromList
              [ ("notify", Operation "notify-send {summary} {body}" ["summary", "body"] True (Just "notify-send"))
              ]
      overridesManifest ops `shouldBe` Map.fromList [("notify-send", "notify")]

    it "returns empty map when no overrides" $ do
      let ops =
            Map.fromList
              [ ("myop", Operation "do-something" [] False Nothing)
              ]
      overridesManifest ops `shouldBe` Map.empty

  describe "writeShims" $ do
    it "creates manifest file" $
      withSystemTempDirectory "shims" $ \dir -> do
        let sp = dir </> "shims.json"
        let ops =
              Map.fromList
                [ ("notify", Operation "notify-send {summary} {body}" ["summary", "body"] True (Just "notify-send"))
                ]
        writeShims sp ops
        contents <- BL.readFile sp
        let decoded = decode contents :: Maybe (Map Text Text)
        decoded `shouldBe` Just (Map.fromList [("notify-send", "notify")])
```

- [ ] **Step 3: Build and test**

Run: `stack build && stack test --test-arguments '--match HostConfig' 2>&1 | tail -20`
Expected: All HostConfig tests pass

- [ ] **Step 4: Commit**

```bash
git add src/Claudespaces/HostConfig.hs test/Claudespaces/HostConfigSpec.hs
git commit -m "refactor: HostConfig drops prefixes, uses fromMaybe, dot syntax

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 9: HostServer module — dot syntax, idioms

**Files:**
- Modify: `src/Claudespaces/HostServer.hs`

- [ ] **Step 1: Rewrite HostServer.hs**

```haskell
module Claudespaces.HostServer
  ( runServer
  , handleRun
  , isRunning
  , startServer
  , stopServerIfLast
  , buildCommand
  , pidFilePath
  , logFilePath
  ) where

import Control.Exception         (SomeException, catch, try)
import Control.Monad             (void, when)
import Control.Monad.IO.Class    (liftIO)
import Data.Aeson                (FromJSON (..), Value (..), object,
                                  withObject, (.:), (.:?), (.=))
import qualified Data.Aeson.Key  as Key
import qualified Data.Aeson.KeyMap as KM
import Data.Map.Strict           (Map)
import qualified Data.Map.Strict as Map
import Data.Text                 (Text)
import qualified Data.Text       as T
import qualified Data.Vector     as V
import Network.HTTP.Types.Status (mkStatus)
import Network.Socket            (Family (..), SockAddr (..), SocketType (..),
                                  close, connect, defaultProtocol, socket,
                                  tupleToHostAddress)
import System.Directory          (getHomeDirectory, removeFile)
import System.Exit               (ExitCode (..))
import System.FilePath           ((</>))
import System.IO.Error           (isDoesNotExistError, ioError, userError)
import System.Posix.Signals      (sigTERM, signalProcess)
import System.Posix.Types        (CPid (..))
import System.Process            (ProcessHandle, readProcessWithExitCode,
                                  spawnProcess)
import Web.Scotty                (ActionM, json, jsonData, literal, post,
                                  scotty, status)

import Claudespaces.HostConfig   (Operation (..))
import Claudespaces.Workspaces   (Workspace (..), Status (..), allWorkspaces,
                                  defaultStateFile)

pidFilePath :: IO FilePath
pidFilePath = do
  h <- getHomeDirectory
  pure $ h </> ".claudespaces" </> "host_bridge.pid"

logFilePath :: IO FilePath
logFilePath = do
  h <- getHomeDirectory
  pure $ h </> ".claudespaces" </> "host_bridge.log"

stripSuffix :: Text -> Text -> Maybe Text
stripSuffix suffix t
  | T.isSuffixOf suffix t = Just (T.dropEnd (T.length suffix) t)
  | otherwise             = Nothing

buildCommand :: Operation -> Map Text Text -> Either Text [String]
buildCommand op namedArgs =
  let parts = T.words op.command
  in mapM substituteOne parts
  where
    substituteOne part =
      case (T.stripPrefix "{" part >>= stripSuffix "}") of
        Just key ->
          case Map.lookup key namedArgs of
            Just val -> Right (T.unpack val)
            Nothing  -> Left ("missing argument: " <> key)
        Nothing -> Right (T.unpack part)

data RunRequest = RunRequest
  { op   :: Text
  , args :: Maybe Value
  } deriving (Show)

instance FromJSON RunRequest where
  parseJSON = withObject "RunRequest" $ \o ->
    RunRequest <$> o .: "op" <*> o .:? "args"

handleRun :: Text -> Value -> Map Text Operation -> IO (Int, Value)
handleRun opName argsVal ops =
  case Map.lookup opName ops of
    Nothing ->
      pure (400, object ["error" .= ("unknown operation: " <> opName)])
    Just op -> do
      let namedArgs = resolveArgs op argsVal
      case buildCommand op namedArgs of
        Left err ->
          pure (400, object ["error" .= err])
        Right [] ->
          pure (400, object ["error" .= ("empty command" :: Text)])
        Right (prog:progArgs) ->
          if op.async
            then do
              result <- try (spawnProcess prog progArgs) :: IO (Either SomeException ProcessHandle)
              case result of
                Left err -> pure (500, object ["error" .= show err])
                Right _  -> pure (200, object ["status" .= ("ok" :: Text)])
            else do
              result <- try (readProcessWithExitCode prog progArgs "") :: IO (Either SomeException (ExitCode, String, String))
              case result of
                Left err -> pure (500, object ["error" .= show err])
                Right (code, out, err) ->
                  let exitCodeInt = case code of
                                      ExitSuccess   -> 0 :: Int
                                      ExitFailure n -> n
                  in pure (200, object
                       [ "stdout"    .= out
                       , "stderr"    .= err
                       , "exit_code" .= exitCodeInt
                       ])

resolveArgs :: Operation -> Value -> Map Text Text
resolveArgs op (Array vec) =
  Map.fromList $ zip op.args (map valueToText (V.toList vec))
resolveArgs _ (Object km) =
  Map.fromList
    [ (Key.toText k, valueToText v)
    | (k, v) <- KM.toList km
    ]
resolveArgs _ _ = Map.empty

valueToText :: Value -> Text
valueToText (String t) = t
valueToText (Number n) = T.pack (show n)
valueToText (Bool b)   = if b then "true" else "false"
valueToText Null       = ""
valueToText v          = T.pack (show v)

runServer :: Int -> Map Text Operation -> IO ()
runServer p ops = scotty p $
  post (literal "/run") $ do
    req <- jsonData :: ActionM RunRequest
    let a = case req.args of
              Just v  -> v
              Nothing -> Object KM.empty
    (code, body) <- liftIO $ handleRun req.op a ops
    status (mkStatus code "")
    json body

isRunning :: Int -> IO Bool
isRunning p = do
  result <- try checkSocket :: IO (Either SomeException ())
  case result of
    Right () -> pure True
    Left _   -> pure False
  where
    checkSocket = do
      sock <- socket AF_INET Stream defaultProtocol
      let addr = SockAddrInet (fromIntegral p) (tupleToHostAddress (127, 0, 0, 1))
      connect sock addr `catch` (\e -> close sock >> ioError (userError (show (e :: SomeException))))
      close sock

startServer :: IO ()
startServer = pure ()

stopServerIfLast :: Text -> FilePath -> IO ()
stopServerIfLast currentName sf = do
  workspaces <- allWorkspaces sf
  let others = filter (\w -> w.name /= currentName && w.status == Running) workspaces
  when (null others) $ do
    pidFile <- pidFilePath
    killServer pidFile `catch` (\e -> case e of
      _ | isDoesNotExistError (e :: IOError) -> pure ()
        | otherwise -> pure ())

killServer :: FilePath -> IO ()
killServer pidFile = do
  contents <- readFile pidFile
  let pid = read (T.unpack (T.strip (T.pack contents))) :: Int
  signalProcess sigTERM (fromIntegral pid :: CPid)
  removeFile pidFile `catch` (\(_ :: IOError) -> pure ())
```

- [ ] **Step 2: Build and test**

Run: `stack build && stack test 2>&1 | tail -20`
Expected: All tests pass

- [ ] **Step 3: Commit**

```bash
git add src/Claudespaces/HostServer.hs
git commit -m "refactor: HostServer uses dot syntax, void, pure

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 10: Lifecycle module — extract shared orchestration

**Files:**
- Modify: `src/Claudespaces/Lifecycle.hs`

- [ ] **Step 1: Implement Lifecycle.hs**

```haskell
module Claudespaces.Lifecycle
  ( attachWithCleanup
  , healStaleWorkspaces
  , ensureBridge
  , checkDocker
  ) where

import Control.Exception        (finally, throwIO)
import Control.Monad            (unless)
import Control.Monad.IO.Class   (liftIO)
import Control.Monad.Reader     (asks)
import Data.Text                (Text)
import qualified Data.Text      as T
import Data.Time.Clock          (getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import System.Exit              (ExitCode (..))
import System.Process           (readProcessWithExitCode)

import Claudespaces.Container   (getRunningContainerIds, attachContainer,
                                  stopContainer)
import Claudespaces.Env         (App, Env (..))
import Claudespaces.Error       (AppError (..))
import Claudespaces.HostServer  (isRunning, startServer, stopServerIfLast)
import Claudespaces.Workspaces  (Status (..), healRunning, updateWorkspace)

nowUtc :: IO Text
nowUtc = T.pack . iso8601Show <$> getCurrentTime

checkDocker :: IO ()
checkDocker = do
  (code, _, _) <- readProcessWithExitCode "docker" ["info"] ""
  unless (code == ExitSuccess) $ throwIO DockerNotReachable

ensureBridge :: Int -> IO ()
ensureBridge p = do
  running <- isRunning p
  unless running startServer

healStaleWorkspaces :: App ()
healStaleWorkspaces = do
  sf <- asks (.stateFile)
  liftIO $ do
    runningIds <- getRunningContainerIds
    healRunning sf runningIds

attachWithCleanup :: Text -> Text -> Int -> App ()
attachWithCleanup wsName cid bridgePort = do
  sf <- asks (.stateFile)
  liftIO $ do
    ensureBridge bridgePort
    updateWorkspace sf wsName (\w -> w { status = Running })
    attachContainer cid
      `finally` do
        now <- nowUtc
        updateWorkspace sf wsName (\w -> w
          { status     = Stopped
          , lastUsedAt = now
          })
        stopContainer cid
        stopServerIfLast wsName sf
```

- [ ] **Step 2: Build**

Run: `stack build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add src/Claudespaces/Lifecycle.hs
git commit -m "feat: add Lifecycle module with shared orchestration logic

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 11: Cli module — App monad, top-level error handler, use Lifecycle

**Files:**
- Modify: `src/Claudespaces/Cli.hs`

- [ ] **Step 1: Rewrite Cli.hs**

```haskell
module Claudespaces.Cli (run) where

import Control.Exception          (catch, throwIO)
import Control.Monad              (unless, when)
import Control.Monad.IO.Class     (liftIO)
import Control.Monad.Reader       (asks, runReaderT)
import Data.List                  (intercalate, nub, sortBy)
import qualified Data.Set         as Set
import Data.Text                  (Text)
import qualified Data.Text        as T
import Data.Time.Clock            (getCurrentTime)
import Data.Time.Format.ISO8601   (iso8601Show)
import Options.Applicative
import System.Directory           (canonicalizePath, createDirectoryIfMissing,
                                   doesDirectoryExist, doesFileExist, copyFile)
import System.Exit                (ExitCode (..), exitFailure)
import System.FilePath            ((</>))
import System.IO                  (hPutStrLn, stderr)
import System.Process             (readProcessWithExitCode)

import qualified Claudespaces.Config     as Config
import qualified Claudespaces.Container  as Container
import qualified Claudespaces.HostConfig as HostConfig
import qualified Claudespaces.HostServer as HostServer
import qualified Claudespaces.Image      as Image
import qualified Claudespaces.Workspaces as Workspaces

import Claudespaces.Env          (App, Env (..), mkEnv)
import Claudespaces.Error        (AppError (..), displayError)
import Claudespaces.Lifecycle    (attachWithCleanup, checkDocker,
                                  healStaleWorkspaces)
import Claudespaces.Workspaces   (Status (..), Workspace (..))

-- CLI data types

data Command
  = New NewOpts
  | Start Text
  | Stop Text
  | Remove Text
  | List

data NewOpts = NewOpts
  { dirs       :: [String]
  , named      :: Maybe Text
  , start      :: Bool
  , image      :: Maybe Text
  , dockerfile :: Maybe String
  }

-- Parsers

commandParser :: Parser Command
commandParser = subparser
  ( command "new"    (info (newCommand    <**> helper) (progDesc "Create a new workspace"))
 <> command "start"  (info (startCommand  <**> helper) (progDesc "Start an existing workspace"))
 <> command "stop"   (info (stopCommand   <**> helper) (progDesc "Stop a running workspace"))
 <> command "remove" (info (removeCommand <**> helper) (progDesc "Remove a workspace"))
 <> command "rm"     (info (removeCommand <**> helper) (progDesc "Remove a workspace"))
 <> command "list"   (info (listCommand   <**> helper) (progDesc "List all workspaces"))
 <> command "ls"     (info (listCommand   <**> helper) (progDesc "List all workspaces"))
  )

newCommand :: Parser Command
newCommand = fmap New $ NewOpts
  <$> some (argument str (metavar "DIRS..."))
  <*> optional (option (T.pack <$> str)
        ( long "named"
       <> short 'n'
       <> metavar "NAME"
       <> help "Workspace name"
        ))
  <*> switch
        ( long "start"
       <> short 's'
       <> help "Start the workspace immediately after creation"
        )
  <*> optional (option (T.pack <$> str)
        ( long "image"
       <> short 'i'
       <> metavar "IMAGE"
       <> help "Docker image to use"
        ))
  <*> optional (option str
        ( long "dockerfile"
       <> short 'd'
       <> metavar "DOCKERFILE"
       <> help "Path to a Dockerfile"
        ))

startCommand :: Parser Command
startCommand = Start . T.pack <$> argument str (metavar "NAME")

stopCommand :: Parser Command
stopCommand = Stop . T.pack <$> argument str (metavar "NAME")

removeCommand :: Parser Command
removeCommand = Remove . T.pack <$> argument str (metavar "NAME")

listCommand :: Parser Command
listCommand = pure List

-- Helpers

nowUtc :: IO Text
nowUtc = T.pack . iso8601Show <$> getCurrentTime

collapseHome :: FilePath -> FilePath -> String
collapseHome h path =
  case stripPrefix' (h ++ "/") path of
    Just rest -> "~/" ++ rest
    Nothing   -> path
  where
    stripPrefix' pre s
      | take (length pre) s == pre = Just (drop (length pre) s)
      | otherwise                  = Nothing

requireWorkspace :: FilePath -> Text -> IO Workspace
requireWorkspace sf wsName = do
  mws <- Workspaces.getByName sf wsName
  case mws of
    Nothing -> throwIO $ WorkspaceNotFound wsName
    Just w  -> pure w

statusText :: Status -> String
statusText Running = "running"
statusText Stopped = "stopped"

-- Commands

cmdNew :: NewOpts -> App ()
cmdNew opts = do
  env <- asks id
  sf  <- asks (.stateFile)
  let h = env.home

  cfg <- liftIO $ Config.loadConfig "." env.globalConfigPath

  case opts.named of
    Just n -> do
      exists <- liftIO $ Workspaces.nameExists sf n
      when exists $ liftIO $ throwIO $ WorkspaceAlreadyExists n
    Nothing -> pure ()

  let mImage = opts.image <|> cfg.image
  let mDockerfile = case opts.dockerfile of
        Just d  -> Just d
        Nothing -> T.unpack <$> cfg.dockerfile
  let mGlobalDockerfile = T.unpack <$> cfg.globalDockerfile

  liftIO checkDocker

  let configDirs = map T.unpack cfg.directories
  let rawDirs    = nub (opts.dirs ++ configDirs)
  resolvedDirs <- liftIO $ mapM canonicalizePath rawDirs
  liftIO $ mapM_ (\d -> do
    ex <- doesDirectoryExist d
    unless ex $ throwIO $ ConfigError $ T.pack $ "Directory does not exist: " <> d
    ) resolvedDirs

  img <- liftIO $ Image.resolveImage mImage mGlobalDockerfile mDockerfile "support"

  healStaleWorkspaces

  allWs <- liftIO $ Workspaces.allWorkspaces sf
  let takenNames = Set.fromList (map (.name) allWs)
  wsName <- case opts.named of
    Just n  -> pure n
    Nothing -> liftIO $ Workspaces.generateName takenNames

  let wsd = Workspaces.stateDir sf wsName
  liftIO $ createDirectoryIfMissing True (wsd </> "projects")

  let claudeJsonSrc = h </> ".claude.json"
  let claudeJsonDst = wsd </> "claude.json"
  liftIO $ do
    srcExists <- doesFileExist claudeJsonSrc
    when srcExists $ copyFile claudeJsonSrc claudeJsonDst

  bridgeCfg <- liftIO $ HostConfig.loadHostBridge env.globalConfigPath
  liftIO $ HostConfig.writeShims env.shimsPath bridgeCfg.operations

  liftIO $ either throwIO pure $ Container.checkBasenameCollision resolvedDirs

  let mounts = Container.buildMounts resolvedDirs wsd bridgeCfg.port cfg.additionalMounts h
  hostMounts <- liftIO $ Container.resolveHostMounts h
  let envVars = Container.buildEnv bridgeCfg.port h
  cid <- liftIO $ Container.createContainer img (mounts ++ hostMounts) envVars

  now <- liftIO nowUtc
  let ws = Workspace
        { name        = wsName
        , dirs        = map T.pack resolvedDirs
        , containerId = cid
        , image       = img
        , createdAt   = now
        , lastUsedAt  = now
        , status      = Stopped
        }
  liftIO $ Workspaces.saveWorkspace sf ws
  liftIO $ putStrLn $ "Created workspace: " <> T.unpack wsName

  when opts.start $
    attachWithCleanup wsName cid bridgeCfg.port

cmdStart :: Text -> App ()
cmdStart wsName = do
  env <- asks id
  sf  <- asks (.stateFile)
  let h = env.home

  _ <- liftIO $ requireWorkspace sf wsName
  liftIO checkDocker
  healStaleWorkspaces

  ws2 <- liftIO $ requireWorkspace sf wsName
  when (ws2.status == Running) $
    liftIO $ throwIO $ WorkspaceAlreadyRunning wsName

  bridgeCfg <- liftIO $ HostConfig.loadHostBridge env.globalConfigPath
  liftIO $ HostConfig.writeShims env.shimsPath bridgeCfg.operations

  let wsd = Workspaces.stateDir sf wsName
  cid <- liftIO $ do
    wsdExists <- doesDirectoryExist wsd
    if wsdExists
      then pure ws2.containerId
      else do
        createDirectoryIfMissing True (wsd </> "projects")
        let claudeJsonSrc = h </> ".claude.json"
        let claudeJsonDst = wsd </> "claude.json"
        srcExists <- doesFileExist claudeJsonSrc
        when srcExists $ copyFile claudeJsonSrc claudeJsonDst
        cfg <- Config.loadConfig "." env.globalConfigPath
        let resolvedDirs = map T.unpack ws2.dirs
        let mounts = Container.buildMounts resolvedDirs wsd bridgeCfg.port cfg.additionalMounts h
        hostMounts' <- Container.resolveHostMounts h
        let envVars = Container.buildEnv bridgeCfg.port h
        newCid <- Container.createContainer ws2.image (mounts ++ hostMounts') envVars
        Workspaces.updateWorkspace sf wsName (\w -> w { containerId = newCid })
        pure newCid

  attachWithCleanup wsName cid bridgeCfg.port

cmdStop :: Text -> App ()
cmdStop wsName = do
  sf <- asks (.stateFile)
  ws <- liftIO $ requireWorkspace sf wsName

  when (ws.status == Stopped) $
    liftIO $ throwIO $ WorkspaceAlreadyStopped wsName

  liftIO $ do
    Container.stopContainer ws.containerId
    now <- nowUtc
    Workspaces.updateWorkspace sf wsName (\w -> w
      { status     = Stopped
      , lastUsedAt = now
      })
    HostServer.stopServerIfLast wsName sf
    putStrLn $ "Stopped workspace: " <> T.unpack wsName

cmdRemove :: Text -> App ()
cmdRemove wsName = do
  sf <- asks (.stateFile)
  ws <- liftIO $ requireWorkspace sf wsName

  let wasRunning = ws.status == Running
  liftIO $ do
    Container.removeContainer ws.containerId
    Workspaces.removeWorkspace sf wsName
    when wasRunning $ HostServer.stopServerIfLast wsName sf
    let wsd = Workspaces.stateDir sf wsName
    removeDir wsd
    putStrLn $ "Removed workspace: " <> T.unpack wsName
  where
    removeDir dir = do
      exists <- doesDirectoryExist dir
      when exists $ do
        (code, _, _) <- readProcessWithExitCode "rm" ["-rf", dir] ""
        case code of
          ExitSuccess   -> pure ()
          ExitFailure _ -> putStrLn $ "Warning: could not remove state dir: " <> dir

cmdList :: App ()
cmdList = do
  sf <- asks (.stateFile)
  h  <- asks (.home)
  ws <- liftIO $ Workspaces.allWorkspaces sf
  let sorted = sortBy (\a b -> compare b.lastUsedAt a.lastUsedAt) ws
  let nameHdr   = "NAME"
      statusHdr = "STATUS"
      dirsHdr   = "DIRS"
      lastHdr   = "LAST USED"
  let rows = map (\w ->
        ( T.unpack w.name
        , statusText w.status
        , intercalate ", " (map (collapseHome h . T.unpack) w.dirs)
        , T.unpack w.lastUsedAt
        )) sorted
  let nameW   = maximum (map (\(n,_,_,_) -> length n) rows ++ [length nameHdr])
      statusW = maximum (map (\(_,s,_,_) -> length s) rows ++ [length statusHdr])
      dirsW   = maximum (map (\(_,_,d,_) -> length d) rows ++ [length dirsHdr])
  let pad n s = s ++ replicate (n - length s) ' '
  let printRow (n, s, d, l) = putStrLn $
        pad nameW n <> "  " <> pad statusW s <> "  " <> pad dirsW d <> "  " <> l
  liftIO $ do
    putStrLn $ pad nameW nameHdr <> "  " <> pad statusW statusHdr <> "  " <> pad dirsW dirsHdr <> "  " <> lastHdr
    putStrLn $ replicate (nameW + 2 + statusW + 2 + dirsW + 2 + length lastHdr) '-'
    mapM_ printRow rows

-- Dispatch + entry point

dispatch :: Command -> App ()
dispatch (New opts)  = cmdNew opts
dispatch (Start n)   = cmdStart n
dispatch (Stop n)    = cmdStop n
dispatch (Remove n)  = cmdRemove n
dispatch List        = cmdList

run :: IO ()
run = do
  env <- mkEnv
  cmd <- execParser opts
  runReaderT (dispatch cmd) env
    `catch` \(e :: AppError) -> do
      hPutStrLn stderr $ "Error: " <> displayError e
      exitFailure
  where
    opts = info (commandParser <**> helper)
      ( fullDesc
     <> progDesc "Manage Claude Code workspaces in Docker containers"
     <> header "claudespaces - workspace manager"
      )
```

- [ ] **Step 2: Build and test**

Run: `stack build && stack test 2>&1 | tail -20`
Expected: BUILD SUCCEEDED, all tests pass

- [ ] **Step 3: Commit**

```bash
git add src/Claudespaces/Cli.hs
git commit -m "refactor: Cli uses App monad, top-level error handler, Lifecycle

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 12: Final build, test, and cleanup

- [ ] **Step 1: Run full build and test suite**

Run: `stack build && stack test 2>&1`
Expected: All tests pass

- [ ] **Step 2: Check for unused imports**

Run: `stack build --ghc-options="-Wunused-imports" 2>&1 | grep -i "unused"`
Fix any warnings found.

- [ ] **Step 3: Fix any remaining issues**

Common things to watch for:
- Ambiguous field references needing type annotations with `DuplicateRecordFields`
- Missing `Control.Applicative ((<|>))` import (should be in `Prelude` for GHC 9.8)
- Any `ioError`/`userError` calls that should have been replaced with `throwIO`/`AppError`

- [ ] **Step 4: Commit cleanup**

```bash
git add -A
git commit -m "chore: remove unused imports, fix warnings after refactor

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```
