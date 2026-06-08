# Haskell Rewrite (Faithful Port) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Python claudespaces CLI with a functionally identical Haskell binary, preserving all external behavior, state file formats, and Docker CLI interactions.

**Architecture:** Seven modules mirroring the Python structure (`Config`, `Workspaces`, `Image`, `Container`, `HostConfig`, `HostServer`, `Cli`), with pure logic separated from IO shells. Docker interaction via CLI shell-outs instead of a library. All tests target pure functions; IO wrappers are thin and untested.

**Tech Stack:** Haskell (Stack), optparse-applicative, aeson, yaml, scotty, process, hspec, hedgehog

---

## File Map

**Create:**
- `stack.yaml` — Stack resolver config
- `package.yaml` — hpack project definition (deps, executables, test suite)
- `app/Main.hs` — entry point (`main = Cli.run`)
- `src/Claudespaces/Config.hs` — YAML config loading & merging
- `src/Claudespaces/Workspaces.hs` — JSON workspace state CRUD
- `src/Claudespaces/Image.hs` — Docker image resolution & build
- `src/Claudespaces/Container.hs` — Docker container operations
- `src/Claudespaces/HostConfig.hs` — Host bridge config & shim manifest
- `src/Claudespaces/HostServer.hs` — Scotty HTTP server + process lifecycle
- `src/Claudespaces/Cli.hs` — optparse-applicative CLI wiring
- `test/Spec.hs` — hspec-discover entry point
- `test/Claudespaces/ConfigSpec.hs` — Config tests
- `test/Claudespaces/WorkspacesSpec.hs` — Workspace state tests
- `test/Claudespaces/ContainerSpec.hs` — Mount building tests
- `test/Claudespaces/ImageSpec.hs` — Tag generation tests
- `test/Claudespaces/HostConfigSpec.hs` — Host bridge config tests

**Keep unchanged:**
- `support/Dockerfile.base` — moved from `claudespaces/Dockerfile.base`
- `support/bin/entrypoint.sh` — moved from `claudespaces/support/bin/entrypoint.sh`
- `support/bin/claudespaces-host` — moved from `claudespaces/support/bin/claudespaces-host`

**Remove (after rewrite complete):**
- `claudespaces/` (Python source)
- `tests/` (Python tests)
- `pyproject.toml`
- `build/`

---

### Task 1: Project scaffold

**Files:**
- Create: `stack.yaml`, `package.yaml`, `app/Main.hs`, `test/Spec.hs`
- Move: `claudespaces/Dockerfile.base` → `support/Dockerfile.base`, `claudespaces/support/bin/` → `support/bin/`

- [ ] **Step 1: Initialize Stack project**

```bash
stack init --resolver lts-23.18
```

If this is a new project with no `.cabal` file yet, skip `stack init` and create `stack.yaml` manually:

```yaml
resolver: lts-23.18

packages:
  - .
```

- [ ] **Step 2: Create `package.yaml`**

```yaml
name: claudespaces
version: 0.1.0
github: aleperaltabazas/claudespaces

dependencies:
  - base >= 4.7 && < 5
  - aeson
  - bytestring
  - cryptohash-md5
  - directory
  - file-embed
  - filepath
  - network
  - optparse-applicative
  - process
  - random
  - scotty
  - text
  - text-conversions
  - time
  - unix
  - yaml

executables:
  claudespaces:
    main: Main.hs
    source-dirs: app
    dependencies:
      - claudespaces
    ghc-options:
      - -threaded
      - -rtsopts
      - -with-rtsopts=-N

library:
  source-dirs: src

tests:
  claudespaces-test:
    main: Spec.hs
    source-dirs: test
    dependencies:
      - claudespaces
      - hspec
      - hedgehog
      - hspec-hedgehog
      - temporary
    ghc-options:
      - -threaded
      - -rtsopts
      - -with-rtsopts=-N
    build-tools:
      - hspec-discover
```

- [ ] **Step 3: Create `app/Main.hs`**

```haskell
module Main where

import qualified Claudespaces.Cli as Cli

main :: IO ()
main = Cli.run
```

- [ ] **Step 4: Create `test/Spec.hs`**

```haskell
{-# OPTIONS_GHC -F -pgmF hspec-discover #-}
```

- [ ] **Step 5: Create stub `src/Claudespaces/Cli.hs`**

```haskell
module Claudespaces.Cli (run) where

run :: IO ()
run = putStrLn "claudespaces"
```

- [ ] **Step 6: Move support files**

```bash
mkdir -p support/bin
cp claudespaces/Dockerfile.base support/Dockerfile.base
cp claudespaces/support/bin/entrypoint.sh support/bin/entrypoint.sh
cp claudespaces/support/bin/claudespaces-host support/bin/claudespaces-host
```

- [ ] **Step 7: Verify it builds and runs**

```bash
stack build
stack exec claudespaces
```

Expected: prints `claudespaces`

```bash
stack test
```

Expected: 0 tests, 0 failures (hspec-discover finds nothing yet)

- [ ] **Step 8: Commit**

```bash
git add stack.yaml package.yaml app/ src/ test/Spec.hs support/
git commit -m "feat: scaffold Haskell project with Stack"
```

---

### Task 2: Config module

**Files:**
- Create: `src/Claudespaces/Config.hs`, `test/Claudespaces/ConfigSpec.hs`

- [ ] **Step 1: Write ConfigSpec tests**

```haskell
{-# LANGUAGE OverloadedStrings #-}

module Claudespaces.ConfigSpec (spec) where

import Test.Hspec
import System.IO.Temp (withSystemTempDirectory)
import System.FilePath ((</>))
import Claudespaces.Config

writeFile' :: FilePath -> String -> IO ()
writeFile' = writeFile

spec :: Spec
spec = do
  describe "parseMount" $ do
    it "parses src:dst as rw" $ do
      parseMount "/host/path:/container/path"
        `shouldBe` Right (MountEntry "/host/path" "/container/path" False)

    it "parses src:dst:rw" $ do
      parseMount "/host/path:/container/path:rw"
        `shouldBe` Right (MountEntry "/host/path" "/container/path" False)

    it "parses src:dst:ro" $ do
      parseMount "/host/path:/container/path:ro"
        `shouldBe` Right (MountEntry "/host/path" "/container/path" True)

    it "rejects single-part entry" $ do
      parseMount "/only-one-part" `shouldSatisfy` isLeft

    it "rejects invalid mode" $ do
      parseMount "/host/path:/container/path:rw2" `shouldSatisfy` isLeft

  describe "loadConfig" $ do
    it "returns empty config when no files exist" $ do
      withSystemTempDirectory "cfg" $ \dir -> do
        cfg <- loadConfig dir (dir </> "nonexistent-global.yaml")
        cfg `shouldBe` emptyConfig

    it "parses image key from local config" $ do
      withSystemTempDirectory "cfg" $ \dir -> do
        writeFile' (dir </> "claudespaces.yml") "image: ubuntu:24.04\n"
        cfg <- loadConfig dir (dir </> "nope.yaml")
        cfgImage cfg `shouldBe` Just "ubuntu:24.04"

    it "parses dockerfile key from local config" $ do
      withSystemTempDirectory "cfg" $ \dir -> do
        writeFile' (dir </> "claudespaces.yml") "dockerfile: ./Dockerfile\n"
        cfg <- loadConfig dir (dir </> "nope.yaml")
        cfgDockerfile cfg `shouldBe` Just "./Dockerfile"

    it "raises on both image and dockerfile in local" $ do
      withSystemTempDirectory "cfg" $ \dir -> do
        writeFile' (dir </> "claudespaces.yml") "image: foo\ndockerfile: ./Dockerfile\n"
        loadConfig dir (dir </> "nope.yaml") `shouldThrow` anyIOException

    it "parses directories from local config" $ do
      withSystemTempDirectory "cfg" $ \dir -> do
        writeFile' (dir </> "claudespaces.yml") "directories:\n  - ~/proj1\n  - ~/proj2\n"
        cfg <- loadConfig dir (dir </> "nope.yaml")
        cfgDirectories cfg `shouldBe` ["~/proj1", "~/proj2"]

    it "returns empty config for empty yaml file" $ do
      withSystemTempDirectory "cfg" $ \dir -> do
        writeFile' (dir </> "claudespaces.yml") ""
        cfg <- loadConfig dir (dir </> "nope.yaml")
        cfg `shouldBe` emptyConfig

    it "exposes global dockerfile as globalDockerfile" $ do
      withSystemTempDirectory "cfg" $ \dir -> do
        writeFile' (dir </> "global.yaml") "dockerfile: ~/.config/claudespaces/Dockerfile\n"
        cfg <- loadConfig dir (dir </> "global.yaml")
        cfgGlobalDockerfile cfg `shouldBe` Just "~/.config/claudespaces/Dockerfile"
        cfgDockerfile cfg `shouldBe` Nothing

    it "raises on both image and dockerfile in global" $ do
      withSystemTempDirectory "cfg" $ \dir -> do
        writeFile' (dir </> "global.yaml") "image: foo\ndockerfile: ./Dockerfile\n"
        loadConfig dir (dir </> "global.yaml") `shouldThrow` anyIOException

    it "local image overrides global image" $ do
      withSystemTempDirectory "cfg" $ \dir -> do
        writeFile' (dir </> "global.yaml") "image: ubuntu:24.04\n"
        writeFile' (dir </> "claudespaces.yml") "image: debian:12\n"
        cfg <- loadConfig dir (dir </> "global.yaml")
        cfgImage cfg `shouldBe` Just "debian:12"

    it "uses global image when no local image" $ do
      withSystemTempDirectory "cfg" $ \dir -> do
        writeFile' (dir </> "global.yaml") "image: debian:12\n"
        cfg <- loadConfig dir (dir </> "global.yaml")
        cfgImage cfg `shouldBe` Just "debian:12"

    it "keeps both global dockerfile and local dockerfile" $ do
      withSystemTempDirectory "cfg" $ \dir -> do
        writeFile' (dir </> "global.yaml") "dockerfile: ~/.config/claudespaces/Dockerfile\n"
        writeFile' (dir </> "claudespaces.yml") "dockerfile: ./Dockerfile\n"
        cfg <- loadConfig dir (dir </> "global.yaml")
        cfgGlobalDockerfile cfg `shouldBe` Just "~/.config/claudespaces/Dockerfile"
        cfgDockerfile cfg `shouldBe` Just "./Dockerfile"

    it "keeps global dockerfile and local image" $ do
      withSystemTempDirectory "cfg" $ \dir -> do
        writeFile' (dir </> "global.yaml") "dockerfile: ~/.config/claudespaces/Dockerfile\n"
        writeFile' (dir </> "claudespaces.yml") "image: debian:12\n"
        cfg <- loadConfig dir (dir </> "global.yaml")
        cfgGlobalDockerfile cfg `shouldBe` Just "~/.config/claudespaces/Dockerfile"
        cfgImage cfg `shouldBe` Just "debian:12"

    it "merges directories from global and local" $ do
      withSystemTempDirectory "cfg" $ \dir -> do
        writeFile' (dir </> "global.yaml") "directories:\n  - ~/global-proj\n"
        writeFile' (dir </> "claudespaces.yml") "directories:\n  - ~/local-proj\n"
        cfg <- loadConfig dir (dir </> "global.yaml")
        cfgDirectories cfg `shouldBe` ["~/global-proj", "~/local-proj"]

  describe "additional mounts" $ do
    it "parses local additional-mounts" $ do
      withSystemTempDirectory "cfg" $ \dir -> do
        writeFile' (dir </> "claudespaces.yml") "additional-mounts:\n  - /src:/dst:ro\n"
        cfg <- loadConfig dir (dir </> "nope.yaml")
        cfgAdditionalMounts cfg `shouldBe` [MountEntry "/src" "/dst" True]

    it "parses global additional-mounts" $ do
      withSystemTempDirectory "cfg" $ \dir -> do
        writeFile' (dir </> "global.yaml") "additional-mounts:\n  - /g:/cg:rw\n"
        cfg <- loadConfig dir (dir </> "global.yaml")
        cfgAdditionalMounts cfg `shouldBe` [MountEntry "/g" "/cg" False]

    it "merges global and local additional-mounts" $ do
      withSystemTempDirectory "cfg" $ \dir -> do
        writeFile' (dir </> "global.yaml") "additional-mounts:\n  - /g:/cg\n"
        writeFile' (dir </> "claudespaces.yml") "additional-mounts:\n  - /l:/cl:ro\n"
        cfg <- loadConfig dir (dir </> "global.yaml")
        cfgAdditionalMounts cfg `shouldBe`
          [ MountEntry "/g" "/cg" False
          , MountEntry "/l" "/cl" True
          ]

    it "raises on overlapping container targets" $ do
      withSystemTempDirectory "cfg" $ \dir -> do
        writeFile' (dir </> "global.yaml") "additional-mounts:\n  - /g:/shared\n"
        writeFile' (dir </> "claudespaces.yml") "additional-mounts:\n  - /l:/shared\n"
        loadConfig dir (dir </> "global.yaml") `shouldThrow` anyIOException

    it "omits additional_mounts when none defined" $ do
      withSystemTempDirectory "cfg" $ \dir -> do
        cfg <- loadConfig dir (dir </> "nope.yaml")
        cfgAdditionalMounts cfg `shouldBe` []

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft _ = False
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
stack test 2>&1 | head -20
```

Expected: compilation error — `Claudespaces.Config` not found.

- [ ] **Step 3: Implement `Config.hs`**

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}

module Claudespaces.Config
  ( Config(..)
  , MountEntry(..)
  , emptyConfig
  , loadConfig
  , parseMount
  ) where

import Data.Maybe (fromMaybe)
import Data.List (nub)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Yaml as Yaml
import Data.Aeson (FromJSON(..), (.:?), (.!=), withObject)
import GHC.Generics (Generic)
import System.FilePath ((</>))
import System.Directory (doesFileExist)
import qualified Data.Set as Set

data MountEntry = MountEntry
  { mountSource   :: Text
  , mountTarget   :: Text
  , mountReadOnly :: Bool
  } deriving (Eq, Show)

data Config = Config
  { cfgImage            :: Maybe Text
  , cfgDockerfile       :: Maybe Text
  , cfgGlobalDockerfile :: Maybe Text
  , cfgDirectories      :: [Text]
  , cfgAdditionalMounts :: [MountEntry]
  } deriving (Eq, Show)

emptyConfig :: Config
emptyConfig = Config Nothing Nothing Nothing [] []

data RawConfig = RawConfig
  { rawImage      :: Maybe Text
  , rawDockerfile :: Maybe Text
  , rawDirs       :: [Text]
  , rawMounts     :: [Text]
  } deriving (Show)

instance FromJSON RawConfig where
  parseJSON = withObject "RawConfig" $ \o -> RawConfig
    <$> o .:? "image"
    <*> o .:? "dockerfile"
    <*> o .:? "directories" .!= []
    <*> o .:? "additional-mounts" .!= []

parseMount :: Text -> Either Text MountEntry
parseMount entry =
  case T.splitOn ":" entry of
    [src, dst]       -> Right (MountEntry src dst False)
    [src, dst, mode] ->
      case mode of
        "ro" -> Right (MountEntry src dst True)
        "rw" -> Right (MountEntry src dst False)
        _    -> Left $ "invalid mount mode " <> tshow mode <> " in " <> tshow entry <> " (expected ro or rw)"
    _ -> Left $ "invalid mount entry: " <> tshow entry <> " (expected src:dst or src:dst:ro|rw)"
  where
    tshow t = "'" <> t <> "'"

loadConfig :: FilePath -> FilePath -> IO Config
loadConfig cwd globalPath = do
  globalCfg <- loadYaml globalPath
  localCfg  <- loadYaml (cwd </> "claudespaces.yml")
  validate globalCfg localCfg
  let image = case rawImage localCfg of
        Just i  -> Just i
        Nothing -> rawImage globalCfg
      dockerfile       = rawDockerfile localCfg
      globalDockerfile = rawDockerfile globalCfg
      dirs = nub (rawDirs globalCfg ++ rawDirs localCfg)
  globalMounts <- parseMounts (rawMounts globalCfg)
  localMounts  <- parseMounts (rawMounts localCfg)
  let globalTargets = Set.fromList (map mountTarget globalMounts)
      localTargets  = Set.fromList (map mountTarget localMounts)
      overlap = Set.intersection globalTargets localTargets
  if not (Set.null overlap)
    then ioError . userError $
      "additional-mounts: duplicate container target(s): " ++
      show (Set.toAscList overlap)
    else pure Config
      { cfgImage            = image
      , cfgDockerfile       = dockerfile
      , cfgGlobalDockerfile = globalDockerfile
      , cfgDirectories      = dirs
      , cfgAdditionalMounts = globalMounts ++ localMounts
      }

validate :: RawConfig -> RawConfig -> IO ()
validate global local = do
  when (hasBoth global) $
    ioError . userError $ "global config: 'image' and 'dockerfile' are mutually exclusive"
  when (hasBoth local) $
    ioError . userError $ "claudespaces.yml: 'image' and 'dockerfile' are mutually exclusive"
  where
    hasBoth c = case (rawImage c, rawDockerfile c) of
      (Just _, Just _) -> True
      _                -> False
    when True  m = m
    when False _ = pure ()

parseMounts :: [Text] -> IO [MountEntry]
parseMounts = mapM $ \t ->
  case parseMount t of
    Left err -> ioError . userError $ T.unpack err
    Right m  -> pure m

loadYaml :: FilePath -> IO RawConfig
loadYaml path = do
  exists <- doesFileExist path
  if not exists
    then pure (RawConfig Nothing Nothing [] [])
    else do
      result <- Yaml.decodeFileEither path
      case result of
        Left _    -> pure (RawConfig Nothing Nothing [] [])
        Right cfg -> pure cfg
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
stack test --test-arguments '--match Config'
```

Expected: all Config tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/Claudespaces/Config.hs test/Claudespaces/ConfigSpec.hs
git commit -m "feat: add Config module with YAML loading and merging"
```

---

### Task 3: Workspaces module

**Files:**
- Create: `src/Claudespaces/Workspaces.hs`, `test/Claudespaces/WorkspacesSpec.hs`

- [ ] **Step 1: Write WorkspacesSpec tests**

```haskell
{-# LANGUAGE OverloadedStrings #-}

module Claudespaces.WorkspacesSpec (spec) where

import Test.Hspec
import System.IO.Temp (withSystemTempDirectory)
import System.FilePath ((</>))
import qualified Data.Set as Set
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as BL
import Claudespaces.Workspaces

mkWorkspace :: Workspace
mkWorkspace = Workspace
  { wsName        = "bold-space"
  , wsDirs        = ["/home/user/proj1"]
  , wsContainerId = "container123"
  , wsImage       = "claudespaces-base:ubuntu-24.04"
  , wsCreatedAt   = "2026-05-26T10:00:00Z"
  , wsLastUsedAt  = "2026-05-26T12:00:00Z"
  , wsStatus      = "stopped"
  }

spec :: Spec
spec = do
  describe "save and read back" $ do
    it "saves and reads a workspace" $ do
      withSystemTempDirectory "ws" $ \dir -> do
        let sf = dir </> "workspaces.json"
        saveWorkspace sf mkWorkspace
        result <- allWorkspaces sf
        length result `shouldBe` 1
        wsName (head result) `shouldBe` "bold-space"

  describe "allWorkspaces" $ do
    it "returns all saved workspaces" $ do
      withSystemTempDirectory "ws" $ \dir -> do
        let sf = dir </> "workspaces.json"
        saveWorkspace sf mkWorkspace { wsName = "ws-a" }
        saveWorkspace sf mkWorkspace { wsName = "ws-b" }
        result <- allWorkspaces sf
        length result `shouldBe` 2

  describe "getByName" $ do
    it "finds workspace by name" $ do
      withSystemTempDirectory "ws" $ \dir -> do
        let sf = dir </> "workspaces.json"
        saveWorkspace sf mkWorkspace
        result <- getByName sf "bold-space"
        result `shouldSatisfy` (/= Nothing)

    it "returns Nothing when not found" $ do
      withSystemTempDirectory "ws" $ \dir -> do
        let sf = dir </> "workspaces.json"
        result <- getByName sf "nope"
        result `shouldBe` Nothing

  describe "nameExists" $ do
    it "returns True when name exists" $ do
      withSystemTempDirectory "ws" $ \dir -> do
        let sf = dir </> "workspaces.json"
        saveWorkspace sf mkWorkspace
        result <- nameExists sf "bold-space"
        result `shouldBe` True

    it "returns False when name does not exist" $ do
      withSystemTempDirectory "ws" $ \dir -> do
        let sf = dir </> "workspaces.json"
        result <- nameExists sf "nope"
        result `shouldBe` False

  describe "updateWorkspace" $ do
    it "changes specified fields" $ do
      withSystemTempDirectory "ws" $ \dir -> do
        let sf = dir </> "workspaces.json"
        saveWorkspace sf mkWorkspace { wsStatus = "running" }
        updateWorkspace sf "bold-space" (\w -> w { wsStatus = "stopped" })
        Just w <- getByName sf "bold-space"
        wsStatus w `shouldBe` "stopped"

    it "leaves other fields intact" $ do
      withSystemTempDirectory "ws" $ \dir -> do
        let sf = dir </> "workspaces.json"
        saveWorkspace sf mkWorkspace { wsStatus = "running" }
        updateWorkspace sf "bold-space" (\w -> w { wsStatus = "stopped" })
        Just w <- getByName sf "bold-space"
        wsDirs w `shouldBe` ["/home/user/proj1"]

    it "raises for unknown name" $ do
      withSystemTempDirectory "ws" $ \dir -> do
        let sf = dir </> "workspaces.json"
        updateWorkspace sf "nope" id `shouldThrow` anyIOException

  describe "removeWorkspace" $ do
    it "removes the correct record" $ do
      withSystemTempDirectory "ws" $ \dir -> do
        let sf = dir </> "workspaces.json"
        saveWorkspace sf mkWorkspace { wsName = "ws-a" }
        saveWorkspace sf mkWorkspace { wsName = "ws-b" }
        removeWorkspace sf "ws-a"
        remaining <- allWorkspaces sf
        length remaining `shouldBe` 1
        wsName (head remaining) `shouldBe` "ws-b"

  describe "healRunning" $ do
    it "marks stale running workspaces as stopped" $ do
      withSystemTempDirectory "ws" $ \dir -> do
        let sf = dir </> "workspaces.json"
        saveWorkspace sf mkWorkspace { wsStatus = "running", wsContainerId = "c1" }
        healRunning sf Set.empty
        Just w <- getByName sf "bold-space"
        wsStatus w `shouldBe` "stopped"

    it "leaves actually running workspaces unchanged" $ do
      withSystemTempDirectory "ws" $ \dir -> do
        let sf = dir </> "workspaces.json"
        saveWorkspace sf mkWorkspace { wsStatus = "running", wsContainerId = "c1" }
        healRunning sf (Set.singleton "c1")
        Just w <- getByName sf "bold-space"
        wsStatus w `shouldBe` "running"

    it "leaves stopped workspaces unchanged" $ do
      withSystemTempDirectory "ws" $ \dir -> do
        let sf = dir </> "workspaces.json"
        saveWorkspace sf mkWorkspace { wsStatus = "stopped", wsContainerId = "c1" }
        healRunning sf Set.empty
        Just w <- getByName sf "bold-space"
        wsStatus w `shouldBe` "stopped"

    it "only changes stale, not all" $ do
      withSystemTempDirectory "ws" $ \dir -> do
        let sf = dir </> "workspaces.json"
        saveWorkspace sf mkWorkspace { wsName = "ws-a", wsStatus = "running", wsContainerId = "c1" }
        saveWorkspace sf mkWorkspace { wsName = "ws-b", wsStatus = "running", wsContainerId = "c2" }
        healRunning sf (Set.singleton "c2")
        Just a <- getByName sf "ws-a"
        Just b <- getByName sf "ws-b"
        wsStatus a `shouldBe` "stopped"
        wsStatus b `shouldBe` "running"

  describe "multiple workspaces same dirs" $ do
    it "allows multiple workspaces for same directories" $ do
      withSystemTempDirectory "ws" $ \dir -> do
        let sf = dir </> "workspaces.json"
        saveWorkspace sf mkWorkspace { wsName = "ws-a", wsDirs = ["/a"] }
        saveWorkspace sf mkWorkspace { wsName = "ws-b", wsDirs = ["/a"] }
        result <- allWorkspaces sf
        length result `shouldBe` 2

  describe "generateName" $ do
    it "generates adjective-noun format" $ do
      name <- generateName Set.empty
      let parts = T.splitOn "-" name
      length parts `shouldBe` 2

    it "avoids collisions with existing names" $ do
      let allButOne = Set.fromList
            [ adj <> "-" <> noun
            | adj <- adjectives, noun <- nouns
            , not (adj == head adjectives && noun == head nouns)
            ]
      name <- generateName allButOne
      name `shouldNotSatisfy` (`Set.member` allButOne)

  describe "migration from sessions.json" $ do
    it "migrates sessions.json dropping id field" $ do
      withSystemTempDirectory "ws" $ \dir -> do
        let sf = dir </> "workspaces.json"
            sessionsFile = dir </> "sessions.json"
        BL.writeFile sessionsFile $ Aeson.encode
          [ Aeson.object
            [ "id" Aeson..= ("abc123" :: String)
            , "name" Aeson..= ("old-session" :: String)
            , "dirs" Aeson..= (["/home/user/proj"] :: [String])
            , "container_id" Aeson..= ("c1" :: String)
            , "image" Aeson..= ("img" :: String)
            , "created_at" Aeson..= ("2026-05-01T00:00:00Z" :: String)
            , "last_used_at" Aeson..= ("2026-05-01T00:00:00Z" :: String)
            , "status" Aeson..= ("stopped" :: String)
            ]
          ]
        result <- allWorkspaces sf
        length result `shouldBe` 1
        wsName (head result) `shouldBe` "old-session"

```

Note: add `import qualified Data.Text as T` at the top of the file (alongside the other imports).

Note: The `where T = Data.Text` at the end is placeholder — this needs a proper import. The actual test file should have `import qualified Data.Text as T` at the top.

- [ ] **Step 2: Run tests to verify they fail**

```bash
stack test 2>&1 | head -20
```

Expected: compilation error — `Claudespaces.Workspaces` not found.

- [ ] **Step 3: Implement `Workspaces.hs`**

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}

module Claudespaces.Workspaces
  ( Workspace(..)
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
  , adjectives
  , nouns
  ) where

import Data.Aeson (FromJSON(..), ToJSON(..), (.:), (.:?), (.=), object, withObject, eitherDecode, encode)
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as BL
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Set as Set
import GHC.Generics (Generic)
import System.Directory (doesFileExist, createDirectoryIfMissing)
import System.FilePath ((</>), takeDirectory)
import System.Random (randomRIO)

data Workspace = Workspace
  { wsName        :: Text
  , wsDirs        :: [Text]
  , wsContainerId :: Text
  , wsImage       :: Text
  , wsCreatedAt   :: Text
  , wsLastUsedAt  :: Text
  , wsStatus      :: Text
  } deriving (Eq, Show, Generic)

instance FromJSON Workspace where
  parseJSON = withObject "Workspace" $ \o -> Workspace
    <$> o .: "name"
    <*> o .: "dirs"
    <*> o .: "container_id"
    <*> o .: "image"
    <*> o .: "created_at"
    <*> o .: "last_used_at"
    <*> o .: "status"

instance ToJSON Workspace where
  toJSON w = object
    [ "name"        .= wsName w
    , "dirs"        .= wsDirs w
    , "container_id" .= wsContainerId w
    , "image"       .= wsImage w
    , "created_at"  .= wsCreatedAt w
    , "last_used_at" .= wsLastUsedAt w
    , "status"      .= wsStatus w
    ]

defaultStateFile :: IO FilePath
defaultStateFile = do
  home <- getHomeDirectory
  pure (home </> ".claudespaces" </> "workspaces.json")

load :: FilePath -> IO [Workspace]
load path = do
  exists <- doesFileExist path
  if not exists
    then do
      migrated <- migrateFromSessions path
      if migrated then load path else pure []
    else do
      contents <- BL.readFile path
      case eitherDecode contents of
        Left _  -> pure []
        Right ws -> pure ws

migrateFromSessions :: FilePath -> IO Bool
migrateFromSessions path = do
  let sessionsFile = takeDirectory path </> "sessions.json"
  exists <- doesFileExist sessionsFile
  if not exists
    then pure False
    else do
      contents <- BL.readFile sessionsFile
      case Aeson.eitherDecode contents :: Either String [Aeson.Value] of
        Left _   -> pure False
        Right vs -> do
          let stripped = map dropId vs
          case mapM Aeson.fromJSON stripped of
            Aeson.Error _   -> pure False
            Aeson.Success ws -> do
              save path ws
              pure True

dropId :: Aeson.Value -> Aeson.Value
dropId (Aeson.Object o) = Aeson.Object (KM.delete "id" o)
dropId v = v

save :: FilePath -> [Workspace] -> IO ()
save path ws = do
  createDirectoryIfMissing True (takeDirectory path)
  BL.writeFile path (encode ws)

allWorkspaces :: FilePath -> IO [Workspace]
allWorkspaces = load

getByName :: FilePath -> Text -> IO (Maybe Workspace)
getByName path name = do
  ws <- load path
  pure $ case filter (\w -> wsName w == name) ws of
    (x:_) -> Just x
    []    -> Nothing

nameExists :: FilePath -> Text -> IO Bool
nameExists path name = do
  result <- getByName path name
  pure $ result /= Nothing

saveWorkspace :: FilePath -> Workspace -> IO ()
saveWorkspace path w = do
  ws <- load path
  save path (ws ++ [w])

updateWorkspace :: FilePath -> Text -> (Workspace -> Workspace) -> IO ()
updateWorkspace path name f = do
  ws <- load path
  if not (any (\w -> wsName w == name) ws)
    then ioError . userError $ "Workspace not found: " ++ T.unpack name
    else save path (map (\w -> if wsName w == name then f w else w) ws)

removeWorkspace :: FilePath -> Text -> IO ()
removeWorkspace path name = do
  ws <- load path
  save path (filter (\w -> wsName w /= name) ws)

healRunning :: FilePath -> Set.Set Text -> IO ()
healRunning path runningIds = do
  ws <- load path
  let healed = map heal ws
  if healed /= ws then save path healed else pure ()
  where
    heal w
      | wsStatus w == "running" && not (wsContainerId w `Set.member` runningIds)
        = w { wsStatus = "stopped" }
      | otherwise = w

stateDir :: FilePath -> Text -> FilePath
stateDir base name = base </> T.unpack name

adjectives :: [Text]
adjectives =
  [ "bold", "calm", "dark", "deep", "fast", "free", "hard", "high"
  , "kind", "last", "late", "long", "loud", "mild", "near", "next"
  , "nice", "open", "pure", "rare", "real", "rich", "safe", "slim"
  , "slow", "soft", "tall", "thin", "tiny", "vast", "warm", "wide"
  , "wild", "wise", "blue", "cold", "cool", "dull", "fair", "firm"
  , "flat", "full", "gray", "keen", "lazy", "lean", "live", "lost"
  , "mad", "neat"
  ]

nouns :: [Text]
nouns =
  [ "space", "orbit", "comet", "cloud", "creek", "delta", "drift"
  , "dusk", "echo", "field", "flame", "flare", "flash", "flow"
  , "forge", "frost", "glade", "gleam", "grove", "haven", "haze"
  , "isle", "lake", "leap", "light", "lodge", "loom", "lunar"
  , "marsh", "mist", "moon", "moss", "nova", "ocean", "peak"
  , "plain", "prism", "pulse", "ridge", "rift", "river", "rock"
  , "shade", "shore", "sky", "slope", "snow", "solar", "spark"
  , "star", "stone"
  ]

generateName :: Set.Set Text -> IO Text
generateName existing = go (10000 :: Int)
  where
    go 0 = ioError . userError $ "Could not generate a unique name after 10000 attempts"
    go n = do
      adjIdx <- randomRIO (0, length adjectives - 1)
      nounIdx <- randomRIO (0, length nouns - 1)
      let name = (adjectives !! adjIdx) <> "-" <> (nouns !! nounIdx)
      if name `Set.member` existing
        then go (n - 1)
        else pure name
```

Note: add `import System.Directory (getHomeDirectory)` for `defaultStateFile`.

- [ ] **Step 4: Run tests to verify they pass**

```bash
stack test --test-arguments '--match Workspaces'
```

Expected: all Workspaces tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/Claudespaces/Workspaces.hs test/Claudespaces/WorkspacesSpec.hs
git commit -m "feat: add Workspaces module with JSON state CRUD"
```

---

### Task 4: HostConfig module

**Files:**
- Create: `src/Claudespaces/HostConfig.hs`, `test/Claudespaces/HostConfigSpec.hs`

- [ ] **Step 1: Write HostConfigSpec tests**

```haskell
{-# LANGUAGE OverloadedStrings #-}

module Claudespaces.HostConfigSpec (spec) where

import Test.Hspec
import System.IO.Temp (withSystemTempDirectory)
import System.FilePath ((</>))
import qualified Data.Map.Strict as Map
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as BL
import Claudespaces.HostConfig

spec :: Spec
spec = do
  describe "loadHostBridge" $ do
    it "returns default port when no config" $ do
      withSystemTempDirectory "hc" $ \dir -> do
        result <- loadHostBridge (dir </> "nope.yaml")
        bridgePort result `shouldBe` defaultPort

    it "builtin notify always present" $ do
      withSystemTempDirectory "hc" $ \dir -> do
        writeFile (dir </> "config.yaml") "host_bridge:\n  operations: {}\n"
        result <- loadHostBridge (dir </> "config.yaml")
        Map.member "notify" (bridgeOperations result) `shouldBe` True

    it "user config wins on conflict" $ do
      withSystemTempDirectory "hc" $ \dir -> do
        writeFile (dir </> "config.yaml") $
          "host_bridge:\n  operations:\n    notify:\n      command: \"custom-notify {msg}\"\n      args:\n        - msg\n      async: true\n"
        result <- loadHostBridge (dir </> "config.yaml")
        let Just op = Map.lookup "notify" (bridgeOperations result)
        opCommand op `shouldBe` "custom-notify {msg}"

    it "loads custom port" $ do
      withSystemTempDirectory "hc" $ \dir -> do
        writeFile (dir </> "config.yaml") "host_bridge:\n  port: 9999\n"
        result <- loadHostBridge (dir </> "config.yaml")
        bridgePort result `shouldBe` 9999

  describe "overridesManifest" $ do
    it "extracts override operations" $ do
      let ops = Map.fromList
            [ ("notify", Operation "notify-send {s}" ["s"] True (Just "notify-send"))
            , ("run", Operation "run {cmd}" ["cmd"] False Nothing)
            ]
      overridesManifest ops `shouldBe` Map.fromList [("notify-send", "notify")]

    it "returns empty map when no overrides" $ do
      let ops = Map.fromList [("run", Operation "run {cmd}" ["cmd"] False Nothing)]
      overridesManifest ops `shouldBe` Map.empty

  describe "writeShims" $ do
    it "creates manifest file" $ do
      withSystemTempDirectory "hc" $ \dir -> do
        let shimsPath = dir </> "shims.json"
            ops = Map.fromList
              [ ("notify", Operation "notify-send {s}" ["s"] True (Just "notify-send"))
              , ("run", Operation "run {cmd}" ["cmd"] False Nothing)
              ]
        writeShims shimsPath ops
        contents <- BL.readFile shimsPath
        let Just m = Aeson.decode contents :: Maybe (Map.Map String String)
        m `shouldBe` Map.fromList [("notify-send", "notify")]
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
stack test 2>&1 | head -20
```

Expected: compilation error — `Claudespaces.HostConfig` not found.

- [ ] **Step 3: Implement `HostConfig.hs`**

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}

module Claudespaces.HostConfig
  ( BridgeConfig(..)
  , Operation(..)
  , defaultPort
  , loadHostBridge
  , overridesManifest
  , writeShims
  , defaultShimsPath
  ) where

import Data.Aeson (FromJSON(..), ToJSON(..), (.:?), (.!=), withObject, encode)
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as BL
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import GHC.Generics (Generic)
import System.Directory (doesFileExist, createDirectoryIfMissing, getHomeDirectory)
import System.FilePath ((</>), takeDirectory)
import qualified Data.Yaml as Yaml

defaultPort :: Int
defaultPort = 7731

data Operation = Operation
  { opCommand  :: Text
  , opArgs     :: [Text]
  , opAsync    :: Bool
  , opOverride :: Maybe Text
  } deriving (Eq, Show)

instance FromJSON Operation where
  parseJSON = withObject "Operation" $ \o -> Operation
    <$> o .:  "command"
    <*> o .:? "args" .!= []
    <*> o .:? "async" .!= False
    <*> o .:? "override"
    where
      o .: k = o Aeson..: k

data BridgeConfig = BridgeConfig
  { bridgePort       :: Int
  , bridgeOperations :: Map Text Operation
  } deriving (Eq, Show)

data RawBridgeYaml = RawBridgeYaml
  { rbPort       :: Maybe Int
  , rbOperations :: Maybe (Map Text Operation)
  } deriving (Show)

instance FromJSON RawBridgeYaml where
  parseJSON = withObject "RawBridgeYaml" $ \o -> RawBridgeYaml
    <$> o .:? "port"
    <*> o .:? "operations"

data RawGlobalYaml = RawGlobalYaml
  { rgHostBridge :: Maybe RawBridgeYaml
  } deriving (Show)

instance FromJSON RawGlobalYaml where
  parseJSON = withObject "RawGlobalYaml" $ \o -> RawGlobalYaml
    <$> o .:? "host_bridge"

builtinOperations :: Map Text Operation
builtinOperations = Map.fromList
  [ ("notify", Operation
      { opCommand  = "notify-send {summary} {body}"
      , opArgs     = ["summary", "body"]
      , opAsync    = True
      , opOverride = Just "notify-send"
      })
  ]

loadHostBridge :: FilePath -> IO BridgeConfig
loadHostBridge globalPath = do
  exists <- doesFileExist globalPath
  if not exists
    then pure BridgeConfig { bridgePort = defaultPort, bridgeOperations = builtinOperations }
    else do
      result <- Yaml.decodeFileEither globalPath
      case result of
        Left _   -> pure BridgeConfig { bridgePort = defaultPort, bridgeOperations = builtinOperations }
        Right raw -> do
          let bridge = rgHostBridge raw
              port = maybe defaultPort (maybe defaultPort id . rbPort) bridge
              userOps = maybe Map.empty (maybe Map.empty id . rbOperations) bridge
              ops = Map.union userOps builtinOperations
          pure BridgeConfig { bridgePort = port, bridgeOperations = ops }

overridesManifest :: Map Text Operation -> Map Text Text
overridesManifest ops = Map.fromList
  [ (override, name)
  | (name, op) <- Map.toList ops
  , Just override <- [opOverride op]
  ]

writeShims :: FilePath -> Map Text Operation -> IO ()
writeShims shimsPath ops = do
  createDirectoryIfMissing True (takeDirectory shimsPath)
  BL.writeFile shimsPath (encode (overridesManifest ops))

defaultShimsPath :: IO FilePath
defaultShimsPath = do
  home <- getHomeDirectory
  pure (home </> ".claudespaces" </> "shims.json")
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
stack test --test-arguments '--match HostConfig'
```

Expected: all HostConfig tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/Claudespaces/HostConfig.hs test/Claudespaces/HostConfigSpec.hs
git commit -m "feat: add HostConfig module with bridge config and shim manifest"
```

---

### Task 5: Container module (pure mount-building logic)

**Files:**
- Create: `src/Claudespaces/Container.hs`, `test/Claudespaces/ContainerSpec.hs`

- [ ] **Step 1: Write ContainerSpec tests**

These tests cover the pure `buildMounts` function and basename collision detection. The docker shell-out functions are thin wrappers and not tested.

```haskell
{-# LANGUAGE OverloadedStrings #-}

module Claudespaces.ContainerSpec (spec) where

import Test.Hspec
import System.IO.Temp (withSystemTempDirectory)
import System.FilePath ((</>))
import System.Directory (createDirectoryIfMissing)
import qualified Data.Text as T
import Claudespaces.Container
import Claudespaces.Config (MountEntry(..))

spec :: Spec
spec = do
  describe "checkBasenameCollision" $ do
    it "raises on duplicate basenames" $ do
      checkBasenameCollision ["/group1/myapp", "/group2/myapp"]
        `shouldThrow` anyIOException

    it "allows distinct basenames" $ do
      checkBasenameCollision ["/group1/app", "/group2/web"]
        `shouldBe` pure ()

  describe "buildMounts" $ do
    it "mounts user dir at /workspace/<basename>" $ do
      withSystemTempDirectory "ctr" $ \dir -> do
        let proj = dir </> "myproject"
        createDirectoryIfMissing True proj
        let stateDir' = dir </> "state"
        createDirectoryIfMissing True stateDir'
        writeFile (stateDir' </> "claude.json") "{}"
        createDirectoryIfMissing True (stateDir' </> "projects")
        let mounts = buildMounts [proj] stateDir' 7731 [] (dir </> "home")
        any (\m -> mTarget m == "/workspace/myproject") mounts `shouldBe` True

    it "user dir mount is read-write" $ do
      withSystemTempDirectory "ctr" $ \dir -> do
        let proj = dir </> "proj"
        createDirectoryIfMissing True proj
        let sd = dir </> "state"
        createDirectoryIfMissing True sd
        let mounts = buildMounts [proj] sd 7731 [] (dir </> "home")
            userMount = head $ filter (\m -> mTarget m == "/workspace/proj") mounts
        mReadOnly userMount `shouldBe` False

    it "mounts state claude.json rw" $ do
      withSystemTempDirectory "ctr" $ \dir -> do
        let sd = dir </> "state"
        createDirectoryIfMissing True sd
        let mounts = buildMounts [] sd 7731 [] (dir </> "home")
            mount = head $ filter (\m -> mTarget m == "/root/.claude.json") mounts
        mSource mount `shouldBe` T.pack (sd </> "claude.json")
        mReadOnly mount `shouldBe` False

    it "mounts state projects rw" $ do
      withSystemTempDirectory "ctr" $ \dir -> do
        let sd = dir </> "state"
        createDirectoryIfMissing True sd
        let mounts = buildMounts [] sd 7731 [] (dir </> "home")
            mount = head $ filter (\m -> mTarget m == "/root/.claude/projects") mounts
        mSource mount `shouldBe` T.pack (sd </> "projects")
        mReadOnly mount `shouldBe` False

    it "appends additional mounts" $ do
      withSystemTempDirectory "ctr" $ \dir -> do
        let sd = dir </> "state"
        createDirectoryIfMissing True sd
        let extra = [MountEntry "/host/docs" "/docs" True]
            mounts = buildMounts [] sd 7731 extra (dir </> "home")
            mount = head $ filter (\m -> mTarget m == "/docs") mounts
        mSource mount `shouldBe` "/host/docs"
        mReadOnly mount `shouldBe` True

  describe "buildEnv" $ do
    it "includes IS_SANDBOX" $ do
      let env = buildEnv 7731 "/home/user"
      lookup "IS_SANDBOX" env `shouldBe` Just "1"

    it "includes HOST_HOME" $ do
      let env = buildEnv 7731 "/home/user"
      lookup "HOST_HOME" env `shouldBe` Just "/home/user"

    it "includes CLAUDESPACES_HOST_PORT" $ do
      let env = buildEnv 9999 "/home/user"
      lookup "CLAUDESPACES_HOST_PORT" env `shouldBe` Just "9999"
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
stack test 2>&1 | head -20
```

Expected: compilation error — `Claudespaces.Container` not found.

- [ ] **Step 3: Implement `Container.hs`**

```haskell
{-# LANGUAGE OverloadedStrings #-}

module Claudespaces.Container
  ( MountSpec(..)
  , buildMounts
  , buildEnv
  , checkBasenameCollision
  , createContainer
  , attachContainer
  , getRunningContainerIds
  , stopContainer
  , removeContainer
  ) where

import Data.List (group, sort)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Set as Set
import System.Directory (doesFileExist, doesDirectoryExist, getHomeDirectory)
import System.Exit (ExitCode(..))
import System.FilePath ((</>), takeBaseName)
import System.Process (callProcess, readProcess, readProcessWithExitCode,
                       createProcess, proc, waitForProcess, delegate_ctlc,
                       std_in, std_out, std_err, StdStream(..))
import System.Environment (lookupEnv)
import Claudespaces.Config (MountEntry(..))

data MountSpec = MountSpec
  { mSource   :: Text
  , mTarget   :: Text
  , mReadOnly :: Bool
  } deriving (Eq, Show)

checkBasenameCollision :: [FilePath] -> IO ()
checkBasenameCollision dirs =
  let basenames = map takeBaseName dirs
      dups = [b | b:_:_ <- group (sort basenames)]
  in case dups of
    (d:_) -> ioError . userError $ "Directories share the same basename: '" ++ d ++ "'"
    []    -> pure ()

buildMounts :: [FilePath] -> FilePath -> Int -> [MountEntry] -> FilePath -> [MountSpec]
buildMounts dirs stateDir' _hostPort additionalMounts homePath =
  -- User workspace dirs
  [ MountSpec (T.pack d) (T.pack ("/workspace/" ++ takeBaseName d)) False
  | d <- dirs
  ]
  ++
  -- Per-workspace state mounts
  [ MountSpec (T.pack (stateDir' </> "claude.json")) "/root/.claude.json" False
  , MountSpec (T.pack (stateDir' </> "projects")) "/root/.claude/projects" False
  ]
  ++
  -- Additional mounts from config
  [ MountSpec (mountSource m) (mountTarget m) (mountReadOnly m)
  | m <- additionalMounts
  ]

buildEnv :: Int -> FilePath -> [(String, String)]
buildEnv hostPort homePath =
  [ ("IS_SANDBOX", "1")
  , ("HOST_HOME", homePath)
  , ("CLAUDESPACES_HOST_PORT", show hostPort)
  ]

mountSpecToArgs :: MountSpec -> [String]
mountSpecToArgs m =
  [ "--mount"
  , "type=bind,source=" ++ T.unpack (mSource m) ++
    ",target=" ++ T.unpack (mTarget m) ++
    if mReadOnly m then ",readonly" else ""
  ]

createContainer :: Text -> [MountSpec] -> [(String, String)] -> IO Text
createContainer image mounts env = do
  let mountArgs = concatMap mountSpecToArgs mounts
      envArgs   = concatMap (\(k,v) -> ["-e", k ++ "=" ++ v]) env
      args = ["create", "--tty", "--interactive", "--user", "root",
              "-w", "/workspace",
              "--add-host", "host.docker.internal:host-gateway"]
              ++ mountArgs ++ envArgs ++ [T.unpack image]
  output <- readProcess "docker" args ""
  pure (T.strip (T.pack output))

attachContainer :: Text -> IO ()
attachContainer containerId = do
  let cid = T.unpack containerId
  callProcess "docker" ["start", cid]
  termVars <- mapM getTermVar ["TERM", "COLORTERM", "PS1"]
  let envArgs = concatMap (\(k,v) -> ["-e", k ++ "=" ++ v]) (concat termVars)
      args = ["exec", "-it"] ++ envArgs ++ [cid, "/claudespaces/entrypoint.sh"]
  (_, _, _, ph) <- createProcess (proc "docker" args)
    { std_in = Inherit, std_out = Inherit, std_err = Inherit, delegate_ctlc = True }
  _ <- waitForProcess ph
  pure ()
  where
    getTermVar name = do
      val <- lookupEnv name
      pure $ case val of
        Just v  -> [(name, v)]
        Nothing -> []

getRunningContainerIds :: IO (Set.Set Text)
getRunningContainerIds = do
  output <- readProcess "docker" ["ps", "-q", "--filter", "status=running"] ""
  let ids = map T.strip $ filter (not . T.null) $ T.lines (T.pack output)
  pure (Set.fromList ids)

stopContainer :: Text -> IO ()
stopContainer containerId =
  callProcess "docker" ["stop", T.unpack containerId]

removeContainer :: Text -> IO ()
removeContainer containerId = do
  (code, _, _) <- readProcessWithExitCode "docker" ["rm", "-f", T.unpack containerId] ""
  pure ()
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
stack test --test-arguments '--match Container'
```

Expected: all Container tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/Claudespaces/Container.hs test/Claudespaces/ContainerSpec.hs
git commit -m "feat: add Container module with mount building and docker CLI wrappers"
```

---

### Task 6: Image module

**Files:**
- Create: `src/Claudespaces/Image.hs`, `test/Claudespaces/ImageSpec.hs`

- [ ] **Step 1: Write ImageSpec tests**

These test the pure tag-generation logic only. Build/inspect are docker shell-outs.

```haskell
{-# LANGUAGE OverloadedStrings #-}

module Claudespaces.ImageSpec (spec) where

import Test.Hspec
import qualified Data.Text as T
import Claudespaces.Image

spec :: Spec
spec = do
  describe "sanitizeTag" $ do
    it "replaces colons and slashes with dashes" $ do
      sanitizeTag "registry.io/org/image:v1.2" `shouldBe` "registry.io-org-image-v1.2"

    it "leaves plain tags unchanged" $ do
      sanitizeTag "ubuntu" `shouldBe` "ubuntu"

  describe "intermediateTag" $ do
    it "starts with claudespaces-base:" $ do
      let tag = intermediateTag "ubuntu:24.04" "abc123def456"
      T.isPrefixOf "claudespaces-base:" tag `shouldBe` True

    it "contains sanitized base tag" $ do
      let tag = intermediateTag "ubuntu:24.04" "abc123"
      T.isInfixOf "ubuntu-24.04" tag `shouldBe` True

    it "ends with hash" $ do
      let tag = intermediateTag "ubuntu:24.04" "abc123"
      T.isSuffixOf "abc123" tag `shouldBe` True

  describe "globalTag" $ do
    it "starts with claudespaces-global:" $ do
      let tag = globalTag "/path/to/Dockerfile" "ubuntu:24.04"
      T.isPrefixOf "claudespaces-global:" tag `shouldBe` True

  describe "customTag" $ do
    it "starts with claudespaces-custom:" $ do
      let tag = customTag "/path/to/Dockerfile" "base:tag"
      T.isPrefixOf "claudespaces-custom:" tag `shouldBe` True
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
stack test 2>&1 | head -20
```

Expected: compilation error.

- [ ] **Step 3: Implement `Image.hs`**

```haskell
{-# LANGUAGE OverloadedStrings #-}

module Claudespaces.Image
  ( resolveImage
  , sanitizeTag
  , intermediateTag
  , globalTag
  , customTag
  , imageExists
  , buildImage
  ) where

import qualified Crypto.Hash.MD5 as MD5
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BS8
import Data.Text (Text)
import qualified Data.Text as T
import System.Directory (doesFileExist, listDirectory, doesDirectoryExist)
import System.Exit (ExitCode(..))
import System.FilePath ((</>), takeDirectory, takeFileName)
import System.IO (hFlush, stdout)
import System.Process (callProcess, readProcessWithExitCode)
import Data.FileEmbed (embedDir)
import Data.List (sort)
import Text.Printf (printf)

sanitizeTag :: Text -> Text
sanitizeTag = T.map (\c -> if c == ':' || c == '/' then '-' else c)

intermediateTag :: Text -> Text -> Text
intermediateTag baseTag hash =
  "claudespaces-base:" <> sanitizeTag baseTag <> "-" <> hash

globalTag :: FilePath -> Text -> Text
globalTag dockerfilePath baseImage =
  let input = T.pack dockerfilePath <> ":" <> baseImage
      hash  = T.pack $ take 12 $ concatMap (printf "%02x") $ BS.unpack $ MD5.hash (BS8.pack (T.unpack input))
  in "claudespaces-global:" <> hash

customTag :: FilePath -> Text -> Text
customTag dockerfilePath baseImage =
  let input = T.pack dockerfilePath <> ":" <> baseImage
      hash  = T.pack $ take 12 $ concatMap (printf "%02x") $ BS.unpack $ MD5.hash (BS8.pack (T.unpack input))
  in "claudespaces-custom:" <> hash

imageExists :: Text -> IO Bool
imageExists tag = do
  (code, _, _) <- readProcessWithExitCode "docker" ["image", "inspect", T.unpack tag] ""
  pure (code == ExitSuccess)

buildImage :: Text -> FilePath -> FilePath -> Text -> IO ()
buildImage tag context dockerfile buildArgBase = do
  putStrLn $ "Building " ++ T.unpack tag ++ " ..."
  hFlush stdout
  callProcess "docker"
    [ "build"
    , "--build-arg", "BASE_IMAGE=" ++ T.unpack buildArgBase
    , "-t", T.unpack tag
    , "-f", dockerfile
    , context
    ]

hashSupportFiles :: FilePath -> IO Text
hashSupportFiles supportDir = do
  exists <- doesDirectoryExist supportDir
  if not exists
    then pure ""
    else do
      files <- sort <$> listDirectoryRecursive supportDir
      contents <- mapM BS.readFile files
      let combined = BS.concat contents
          hash = MD5.hash combined
      pure $ T.pack $ take 12 $ concatMap (printf "%02x") (BS.unpack hash)

listDirectoryRecursive :: FilePath -> IO [FilePath]
listDirectoryRecursive dir = do
  entries <- listDirectory dir
  let paths = map (dir </>) entries
  files <- concat <$> mapM (\p -> do
    isDir <- doesDirectoryExist p
    if isDir then listDirectoryRecursive p else pure [p]) paths
  pure (sort files)

resolveImage :: Maybe Text -> Maybe FilePath -> Maybe FilePath -> FilePath -> IO Text
resolveImage mImage mGlobalDockerfile mDockerfile supportDir = do
  baseTag <- buildPreClaudeBase mImage mGlobalDockerfile mDockerfile
  dockerfileBase <- BS.readFile (supportDir </> "Dockerfile.base")
  supportHash <- hashSupportFiles (supportDir </> "support")
  let baseHash = T.pack $ take 12 $ concatMap (printf "%02x") $
        BS.unpack $ MD5.hash (BS.concat [dockerfileBase, BS8.pack (T.unpack supportHash)])
      tag = intermediateTag baseTag baseHash
  exists <- imageExists tag
  if exists
    then pure tag
    else do
      buildImage tag supportDir "Dockerfile.base" baseTag
      pure tag

buildPreClaudeBase :: Maybe Text -> Maybe FilePath -> Maybe FilePath -> IO Text
buildPreClaudeBase mImage mGlobalDockerfile mDockerfile = do
  case mGlobalDockerfile of
    Just gdf -> do
      exists <- doesFileExist gdf
      if not exists
        then ioError . userError $ "Global Dockerfile not found: " ++ gdf
        else pure ()
    Nothing -> pure ()

  case mDockerfile of
    Just df -> do
      exists <- doesFileExist df
      if not exists
        then ioError . userError $ "Dockerfile not found: " ++ df
        else pure ()
    Nothing -> pure ()

  let current0 = maybe "ubuntu:24.04" id mImage

  current1 <- case mGlobalDockerfile of
    Nothing  -> pure current0
    Just gdf -> do
      let absPath = gdf
          tag = globalTag absPath current0
      exists <- imageExists tag
      if exists
        then pure (T.unpack tag)
        else do
          buildImage (T.pack tag) (takeDirectory absPath) (takeFileName absPath) (T.pack current0)
          pure (T.unpack tag)

  current2 <- case mDockerfile of
    Nothing -> pure current1
    Just df -> do
      let absPath = df
          tag = customTag absPath (T.pack current1)
      putStrLn $ "Building " ++ show tag ++ " ..."
      buildImage tag (takeDirectory absPath) (takeFileName absPath) (T.pack current1)
      pure (T.unpack tag)

  pure (T.pack current2)
```

Note: `resolveImage` takes `supportDir` as a parameter rather than using `file-embed` in this step. The `file-embed` integration (writing embedded files to a temp dir for docker build context) will be wired in `Cli.hs`.

- [ ] **Step 4: Run tests to verify they pass**

```bash
stack test --test-arguments '--match Image'
```

Expected: all Image tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/Claudespaces/Image.hs test/Claudespaces/ImageSpec.hs
git commit -m "feat: add Image module with tag generation and docker build"
```

---

### Task 7: HostServer module

**Files:**
- Create: `src/Claudespaces/HostServer.hs`

No test file — the tests that make sense for this module (handle_run, is_running, stop_server_if_last) require process mocking. We test the pure `buildCommand` logic inline.

- [ ] **Step 1: Implement `HostServer.hs`**

```haskell
{-# LANGUAGE OverloadedStrings #-}

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

import Control.Exception (catch, SomeException)
import Data.Aeson (Value(..), object, (.=), encode, eitherDecode)
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as BL
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import Network.Socket (socket, connect, close, defaultProtocol, socketToHandle,
                        Family(..), SocketType(..), SockAddr(..),
                        tupleToHostAddress)
import System.Directory (doesFileExist, createDirectoryIfMissing, removeFile, getHomeDirectory)
import System.Exit (ExitCode(..))
import System.FilePath ((</>))
import System.IO (IOMode(..), hClose)
import System.Process (readProcessWithExitCode, spawnProcess, ProcessHandle)
import System.Posix.Signals (signalProcess, sigTERM)
import System.Posix.Types (ProcessID)
import Web.Scotty (scotty, post, capture, jsonData, json, status, ActionM)
import qualified Network.HTTP.Types.Status as HTTP

import Claudespaces.HostConfig (Operation(..), BridgeConfig(..))
import Claudespaces.Workspaces (allWorkspaces, Workspace(..), defaultStateFile)

pidFilePath :: IO FilePath
pidFilePath = do
  home <- getHomeDirectory
  pure (home </> ".claudespaces" </> "host_bridge.pid")

logFilePath :: IO FilePath
logFilePath = do
  home <- getHomeDirectory
  pure (home </> ".claudespaces" </> "host_bridge.log")

buildCommand :: Operation -> Map Text Text -> Either Text [String]
buildCommand op namedArgs =
  let parts = words (T.unpack (opCommand op))
  in mapM (substitute namedArgs) parts
  where
    substitute args s =
      if "{" `isPrefixOf` s && "}" `isSuffixOf` s
        then let key = T.pack $ init (tail s)
             in case Map.lookup key args of
                  Just v  -> Right (T.unpack v)
                  Nothing -> Left $ "missing argument: " <> key
        else Right s
    isPrefixOf p s = take (length p) s == p
    isSuffixOf p s = drop (length s - length p) s == p

handleRun :: Text -> Value -> Map Text Operation -> IO (Int, Value)
handleRun opName args operations =
  case Map.lookup opName operations of
    Nothing -> pure (400, object ["error" .= ("unknown operation: '" <> opName <> "'" :: Text)])
    Just op -> do
      let named = case args of
            Array arr ->
              let argNames = opArgs op
                  vals = map (\(Aeson.String s) -> s) (toList arr)
              in Map.fromList (zip argNames vals)
            Object o ->
              Map.fromList [(k, v) | (k, Aeson.String v) <- map (\(k,v) -> (Aeson.toText k, v)) (KM.toList o)]
            _ -> Map.empty
      case buildCommand op named of
        Left err -> pure (400, object ["error" .= err])
        Right cmd -> do
          if opAsync op
            then do
              _ <- spawnProcess (head cmd) (tail cmd)
              pure (200, object ["status" .= ("ok" :: Text)])
            else do
              (code, stdout', stderr') <- readProcessWithExitCode (head cmd) (tail cmd) ""
              pure (200, object
                [ "stdout" .= stdout'
                , "stderr" .= stderr'
                , "exit_code" .= case code of
                    ExitSuccess   -> 0 :: Int
                    ExitFailure n -> n
                ])
          `catch` \(e :: SomeException) ->
            pure (500, object ["error" .= ("command not found: '" <> T.pack (head cmd) <> "'" :: Text)])
      where
        toList (Array a) = foldr (:) [] a
        toList _ = []

runServer :: Int -> Map Text Operation -> IO ()
runServer port operations =
  scotty port $ do
    post "/run" $ do
      body <- jsonData
      let opName = case body of
            Object o -> case KM.lookup "op" o of
              Just (Aeson.String s) -> s
              _ -> ""
            _ -> ""
          args = case body of
            Object o -> case KM.lookup "args" o of
              Just v  -> v
              Nothing -> object []
            _ -> object []
      (code, response) <- liftIO $ handleRun opName args operations
      status (HTTP.mkStatus code "")
      json response
  where
    liftIO = Web.Scotty.liftIO

isRunning :: Int -> IO Bool
isRunning port = do
  s <- socket AF_INET Stream defaultProtocol
  result <- (do
    connect s (SockAddrInet (fromIntegral port) (tupleToHostAddress (127,0,0,1)))
    close s
    pure True) `catch` \(_ :: SomeException) -> do
      close s
      pure False
  pure result

startServer :: IO ()
startServer = do
  pidPath <- pidFilePath
  logPath <- logFilePath
  createDirectoryIfMissing True (takeDirectory pidPath)
  -- The server is started by re-invoking the claudespaces binary with a hidden flag.
  -- For now, we spawn the process directly.
  -- This will be wired in Cli.hs
  pure ()

stopServerIfLast :: Text -> FilePath -> IO ()
stopServerIfLast stoppedName stateFile = do
  ws <- allWorkspaces stateFile
  let remaining = filter (\w -> wsName w /= stoppedName && wsStatus w == "running") ws
  if not (null remaining)
    then pure ()
    else do
      pidPath <- pidFilePath
      exists <- doesFileExist pidPath
      if not exists
        then pure ()
        else do
          pidStr <- readFile pidPath
          let pid = read (filter (/= '\n') pidStr) :: Int
          signalProcess sigTERM (fromIntegral pid)
            `catch` \(_ :: SomeException) -> pure ()
          removeFile pidPath
            `catch` \(_ :: SomeException) -> pure ()
  where
    takeDirectory p = reverse $ dropWhile (/= '/') $ reverse p
```

Note: The `handleRun`, `buildCommand`, `isRunning`, and `stopServerIfLast` functions are implemented. `startServer` is a stub — full server spawning is wired in `Cli.hs` since it needs to know the binary path. The `liftIO` import from Scotty handles the `IO` → `ActionM` lift.

- [ ] **Step 2: Verify it compiles**

```bash
stack build
```

Expected: compiles successfully.

- [ ] **Step 3: Commit**

```bash
git add src/Claudespaces/HostServer.hs
git commit -m "feat: add HostServer module with Scotty server and process lifecycle"
```

---

### Task 8: Cli module

**Files:**
- Create: `src/Claudespaces/Cli.hs` (replace stub from Task 1)

- [ ] **Step 1: Implement `Cli.hs`**

```haskell
{-# LANGUAGE OverloadedStrings #-}

module Claudespaces.Cli (run) where

import Control.Exception (bracket_, finally, catch, SomeException)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Options.Applicative
import System.Directory (doesDirectoryExist, doesFileExist, createDirectoryIfMissing,
                         getHomeDirectory, removeDirectoryRecursive, canonicalizePath)
import System.Exit (exitWith, ExitCode(..), exitFailure)
import System.FilePath ((</>), takeBaseName)
import qualified Data.Set as Set

import qualified Claudespaces.Config as Config
import qualified Claudespaces.Container as Container
import qualified Claudespaces.HostConfig as HostConfig
import qualified Claudespaces.HostServer as HostServer
import qualified Claudespaces.Image as Image
import qualified Claudespaces.Workspaces as Workspaces

data Command
  = New NewOpts
  | Start Text
  | Stop Text
  | Remove Text
  | List

data NewOpts = NewOpts
  { newDirs       :: [String]
  , newNamed      :: Maybe Text
  , newStart      :: Bool
  , newImage      :: Maybe Text
  , newDockerfile :: Maybe String
  }

commandParser :: Parser Command
commandParser = subparser
  ( command "new" (info (New <$> newOptsParser) (progDesc "Create a new workspace"))
  <> command "start" (info (Start . T.pack <$> argument str (metavar "NAME")) (progDesc "Start a workspace"))
  <> command "stop" (info (Stop . T.pack <$> argument str (metavar "NAME")) (progDesc "Stop a workspace"))
  <> command "remove" (info (Remove . T.pack <$> argument str (metavar "NAME")) (progDesc "Remove a workspace"))
  <> command "rm" (info (Remove . T.pack <$> argument str (metavar "NAME")) (progDesc "Remove a workspace (alias)"))
  <> command "list" (info (pure List) (progDesc "List workspaces"))
  <> command "ls" (info (pure List) (progDesc "List workspaces (alias)"))
  )

newOptsParser :: Parser NewOpts
newOptsParser = NewOpts
  <$> some (argument str (metavar "DIRS..."))
  <*> optional (T.pack <$> strOption (long "named" <> metavar "NAME"))
  <*> switch (long "start")
  <*> optional (T.pack <$> strOption (long "image" <> metavar "IMAGE"))
  <*> optional (strOption (long "dockerfile" <> metavar "DOCKERFILE"))

run :: IO ()
run = do
  cmd <- execParser (info (commandParser <**> helper) (fullDesc <> progDesc "claudespaces"))
  case cmd of
    New opts   -> cmdNew opts
    Start name -> cmdStart name
    Stop name  -> cmdStop name
    Remove name -> cmdRemove name
    List       -> cmdList

nowUtc :: IO Text
nowUtc = do
  t <- getCurrentTime
  pure $ T.pack $ iso8601Show t

stateFile :: IO FilePath
stateFile = Workspaces.defaultStateFile

globalConfigPath :: IO FilePath
globalConfigPath = do
  home <- getHomeDirectory
  pure (home </> ".config" </> "claudespaces" </> "claudespaces.yaml")

supportDir :: FilePath
supportDir = "support"  -- This will be replaced with file-embed extraction at build time

startBridge :: Int -> IO ()
startBridge port = do
  running <- HostServer.isRunning port
  if running then pure () else HostServer.startServer

cmdNew :: NewOpts -> IO ()
cmdNew opts = do
  gcPath <- globalConfigPath
  cfg <- Config.loadConfig "." gcPath
    `catch` \(e :: SomeException) -> do
      TIO.putStrLn (T.pack (show e))
      exitWith (ExitFailure 1)

  sf <- stateFile

  case newNamed opts of
    Just name -> do
      exists <- Workspaces.nameExists sf name
      if exists
        then do
          TIO.putStrLn $ "Workspace '" <> name <> "' already exists."
          exitWith (ExitFailure 1)
        else pure ()
    Nothing -> pure ()

  let globalDockerfile = T.unpack <$> Config.cfgGlobalDockerfile cfg
      image = case (newImage opts, newDockerfile opts) of
        (Just i, _)  -> Just i
        (_, Just _)  -> Nothing
        _            -> Config.cfgImage cfg
      dockerfile = case (newImage opts, newDockerfile opts) of
        (_, Just d)  -> Just d
        (Just _, _)  -> Nothing
        _            -> T.unpack <$> Config.cfgDockerfile cfg

  let cfgDirs = map (T.unpack) (Config.cfgDirectories cfg)
  let cliDirs = newDirs opts
  let allDirs' = Set.toAscList . Set.fromList $ cfgDirs ++ cliDirs

  allDirs <- if null allDirs'
    then do
      hasLocal <- doesFileExist "claudespaces.yml"
      if hasLocal
        then do
          cwd <- canonicalizePath "."
          pure [cwd]
        else do
          TIO.putStrLn "No directories specified. Usage: claudespaces new DIR [DIR...]"
          exitWith (ExitFailure 1)
    else pure allDirs'

  -- Verify docker is reachable
  dockerOk <- checkDocker
  if not dockerOk then do
    TIO.putStrLn "Docker is not running or not reachable."
    exitWith (ExitFailure 1)
  else pure ()

  -- Resolve and validate directories
  resolvedDirs <- mapM (\d -> do
    absD <- canonicalizePath d
    exists <- doesDirectoryExist absD
    if not exists then do
      isFile <- doesFileExist absD
      if isFile
        then do
          TIO.putStrLn $ "Not a directory: " <> T.pack absD
          exitWith (ExitFailure 1)
        else do
          TIO.putStrLn $ "Directory not found: " <> T.pack absD
          exitWith (ExitFailure 1)
    else pure absD) allDirs

  -- Resolve image
  resolvedImage <- Image.resolveImage
    (image)
    (globalDockerfile)
    (dockerfile)
    supportDir
    `catch` \(e :: SomeException) -> do
      TIO.putStrLn (T.pack (show e))
      exitWith (ExitFailure 1)

  -- Heal stale workspaces
  runningIds <- Container.getRunningContainerIds
  Workspaces.healRunning sf runningIds

  -- Generate name
  existingNames <- Set.fromList . map Workspaces.wsName <$> Workspaces.allWorkspaces sf
  name <- case newNamed opts of
    Just n  -> pure n
    Nothing -> Workspaces.generateName existingNames

  -- Create state dir
  home <- getHomeDirectory
  let sd = home </> ".claudespaces" </> T.unpack name
  createDirectoryIfMissing True sd
  createDirectoryIfMissing True (sd </> "projects")
  let claudeJson = sd </> "claude.json"
  claudeExists <- doesFileExist claudeJson
  if not claudeExists then do
    let hostClaudeJson = home </> ".claude.json"
    hostExists <- doesFileExist hostClaudeJson
    contents <- if hostExists then readFile hostClaudeJson else pure "{}"
    writeFile claudeJson contents
  else pure ()

  -- Load host bridge config
  bridgeCfg <- HostConfig.loadHostBridge =<< globalConfigPath
  shimsPath <- HostConfig.defaultShimsPath
  HostConfig.writeShims shimsPath (HostConfig.bridgeOperations bridgeCfg)

  let additionalMounts = map (\m -> Config.MountEntry
        (Config.mountSource m) (Config.mountTarget m) (Config.mountReadOnly m))
        (Config.cfgAdditionalMounts cfg)

  -- Check basename collisions
  Container.checkBasenameCollision resolvedDirs
    `catch` \(e :: SomeException) -> do
      TIO.putStrLn (T.pack (show e))
      exitWith (ExitFailure 1)

  -- Build mounts and create container
  let mounts = Container.buildMounts resolvedDirs sd (HostConfig.bridgePort bridgeCfg)
                  (Config.cfgAdditionalMounts cfg) home
  containerId <- Container.createContainer (T.pack resolvedImage) mounts
                   (Container.buildEnv (HostConfig.bridgePort bridgeCfg) home)

  -- Save workspace
  now <- nowUtc
  let workspace = Workspaces.Workspace
        { Workspaces.wsName        = name
        , Workspaces.wsDirs        = map T.pack resolvedDirs
        , Workspaces.wsContainerId = containerId
        , Workspaces.wsImage       = T.pack resolvedImage
        , Workspaces.wsCreatedAt   = now
        , Workspaces.wsLastUsedAt  = now
        , Workspaces.wsStatus      = "stopped"
        }
  Workspaces.saveWorkspace sf workspace
  TIO.putStrLn $ "Created workspace '" <> name <> "'."

  -- Optionally start
  if newStart opts then do
    startBridge (HostConfig.bridgePort bridgeCfg)
    Workspaces.updateWorkspace sf name (\w -> w { Workspaces.wsStatus = "running" })
    Container.attachContainer containerId
      `finally` do
        now' <- nowUtc
        Workspaces.updateWorkspace sf name (\w -> w
          { Workspaces.wsStatus = "stopped"
          , Workspaces.wsLastUsedAt = now'
          })
        Container.stopContainer containerId
        HostServer.stopServerIfLast name sf
  else pure ()

cmdStart :: Text -> IO ()
cmdStart name = do
  sf <- stateFile
  mWorkspace <- Workspaces.getByName sf name
  case mWorkspace of
    Nothing -> do
      TIO.putStrLn $ "Workspace '" <> name <> "' not found."
      exitWith (ExitFailure 1)
    Just ws -> do
      dockerOk <- checkDocker
      if not dockerOk then do
        TIO.putStrLn "Docker is not running or not reachable."
        exitWith (ExitFailure 1)
      else pure ()

      runningIds <- Container.getRunningContainerIds
      Workspaces.healRunning sf runningIds

      ws' <- Workspaces.getByName sf name
      case ws' of
        Just w | Workspaces.wsStatus w == "running" -> do
          TIO.putStrLn $ "Workspace '" <> name <> "' is already running."
          exitWith (ExitFailure 1)
        Just w -> do
          gcPath <- globalConfigPath
          bridgeCfg <- HostConfig.loadHostBridge gcPath
          shimsPath <- HostConfig.defaultShimsPath
          HostConfig.writeShims shimsPath (HostConfig.bridgeOperations bridgeCfg)

          home <- getHomeDirectory
          let sd = home </> ".claudespaces" </> T.unpack name
          sdExists <- doesDirectoryExist sd
          cid <- if not sdExists then do
            cfg <- Config.loadConfig "." gcPath
            let additionalMounts = Config.cfgAdditionalMounts cfg
            TIO.putStrLn $ "Migrating workspace '" <> name <> "' to new mount layout..."
            createDirectoryIfMissing True sd
            createDirectoryIfMissing True (sd </> "projects")
            let claudeJson = sd </> "claude.json"
            let hostClaudeJson = home </> ".claude.json"
            hostExists <- doesFileExist hostClaudeJson
            contents <- if hostExists then readFile hostClaudeJson else pure "{}"
            writeFile claudeJson contents
            Container.removeContainer (Workspaces.wsContainerId w)
            let mounts = Container.buildMounts
                  (map T.unpack (Workspaces.wsDirs w)) sd
                  (HostConfig.bridgePort bridgeCfg) additionalMounts home
            newId <- Container.createContainer (Workspaces.wsImage w) mounts
                      (Container.buildEnv (HostConfig.bridgePort bridgeCfg) home)
            Workspaces.updateWorkspace sf name (\ww -> ww { Workspaces.wsContainerId = newId })
            pure newId
          else pure (Workspaces.wsContainerId w)

          startBridge (HostConfig.bridgePort bridgeCfg)
          Workspaces.updateWorkspace sf name (\ww -> ww { Workspaces.wsStatus = "running" })
          Container.attachContainer cid
            `finally` do
              now <- nowUtc
              Workspaces.updateWorkspace sf name (\ww -> ww
                { Workspaces.wsStatus = "stopped"
                , Workspaces.wsLastUsedAt = now
                })
              Container.stopContainer cid
              HostServer.stopServerIfLast name sf
        Nothing -> do
          TIO.putStrLn $ "Workspace '" <> name <> "' not found."
          exitWith (ExitFailure 1)

cmdStop :: Text -> IO ()
cmdStop name = do
  sf <- stateFile
  mWorkspace <- Workspaces.getByName sf name
  case mWorkspace of
    Nothing -> do
      TIO.putStrLn $ "Workspace '" <> name <> "' not found."
      exitWith (ExitFailure 1)
    Just ws
      | Workspaces.wsStatus ws == "stopped" -> do
          TIO.putStrLn $ "Workspace '" <> name <> "' is already stopped."
      | otherwise -> do
          dockerOk <- checkDocker
          if not dockerOk then do
            TIO.putStrLn "Docker is not running or not reachable."
            exitWith (ExitFailure 1)
          else pure ()
          Container.stopContainer (Workspaces.wsContainerId ws)
            `catch` \(e :: SomeException) -> do
              TIO.putStrLn $ "Failed to stop container: " <> T.pack (show e)
              exitWith (ExitFailure 1)
          Workspaces.updateWorkspace sf name (\w -> w { Workspaces.wsStatus = "stopped" })
          HostServer.stopServerIfLast name sf
          TIO.putStrLn $ "Stopped workspace '" <> name <> "'."

cmdRemove :: Text -> IO ()
cmdRemove name = do
  sf <- stateFile
  mWorkspace <- Workspaces.getByName sf name
  case mWorkspace of
    Nothing -> do
      TIO.putStrLn $ "Workspace '" <> name <> "' not found."
      exitWith (ExitFailure 1)
    Just ws -> do
      dockerOk <- checkDocker
      if not dockerOk then do
        TIO.putStrLn "Docker is not running or not reachable."
        exitWith (ExitFailure 1)
      else pure ()
      Container.removeContainer (Workspaces.wsContainerId ws)
        `catch` \(e :: SomeException) -> do
          TIO.putStrLn $ "Failed to remove container: " <> T.pack (show e)
          exitWith (ExitFailure 1)
      Workspaces.removeWorkspace sf name
      home <- getHomeDirectory
      let sd = home </> ".claudespaces" </> T.unpack name
      sdExists <- doesDirectoryExist sd
      if sdExists then removeDirectoryRecursive sd else pure ()
      TIO.putStrLn $ "Removed workspace '" <> name <> "'."

cmdList :: IO ()
cmdList = do
  sf <- stateFile
  ws <- Workspaces.allWorkspaces sf
  if null ws then do
    TIO.putStrLn "No workspaces found."
  else do
    home <- getHomeDirectory
    let collapse p = if T.pack home `T.isPrefixOf` p
          then "~" <> T.drop (T.length (T.pack home)) p
          else p
        fmtDirs dirs = let joined = T.intercalate ", " (map collapse dirs)
          in if T.length joined > 40 then T.take 39 joined <> "…" else joined
        sorted = sortBy (\a b -> compare (Workspaces.wsLastUsedAt b) (Workspaces.wsLastUsedAt a)) ws
    TIO.putStrLn $ padRight 20 "NAME" <> padRight 10 "STATUS" <> padRight 42 "DIRS" <> "LAST USED"
    TIO.putStrLn (T.replicate 85 "-")
    mapM_ (\w ->
      TIO.putStrLn $ padRight 20 (Workspaces.wsName w)
        <> padRight 10 (Workspaces.wsStatus w)
        <> padRight 42 (fmtDirs (Workspaces.wsDirs w))
        <> T.take 16 (Workspaces.wsLastUsedAt w)
      ) sorted
  where
    padRight n t = T.take n (t <> T.replicate n " ")
    sortBy f = foldr insert []
      where insert x [] = [x]
            insert x (y:ys) = case f x y of
              GT -> y : insert x ys
              _  -> x : y : ys

checkDocker :: IO Bool
checkDocker = do
  (code, _, _) <- readProcessWithExitCode "docker" ["info"] ""
  pure (code == ExitSuccess)
  `catch` \(_ :: SomeException) -> pure False
  where
    readProcessWithExitCode = System.Process.readProcessWithExitCode
```

- [ ] **Step 2: Verify it compiles**

```bash
stack build
```

Expected: compiles successfully.

- [ ] **Step 3: Verify basic commands work**

```bash
stack exec claudespaces -- --help
stack exec claudespaces -- list
```

Expected: help text shows all subcommands; list shows "No workspaces found." or existing workspaces.

- [ ] **Step 4: Commit**

```bash
git add src/Claudespaces/Cli.hs
git commit -m "feat: add Cli module with all subcommands"
```

---

### Task 9: Update CLAUDE.md and clean up Python

**Files:**
- Modify: `CLAUDE.md`
- Remove: `claudespaces/`, `tests/`, `pyproject.toml`, `build/`

- [ ] **Step 1: Update CLAUDE.md with Haskell commands**

Replace the Commands section with:

```markdown
## Commands

```bash
# Build
stack build

# Run all tests
stack test

# Run tests for a single module
stack test --test-arguments '--match Config'

# Run the CLI
stack exec claudespaces -- --help
stack exec claudespaces -- new ~/project
stack exec claudespaces -- list
```
```

Update the Architecture section to reflect Haskell module names and the docker CLI approach.

- [ ] **Step 2: Remove Python files**

```bash
rm -rf claudespaces/ tests/ pyproject.toml build/
```

- [ ] **Step 3: Verify everything still builds and tests pass**

```bash
stack build && stack test
```

Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "chore: remove Python code, update CLAUDE.md for Haskell"
```

---

### Task 10: Manual smoke test

- [ ] **Step 1: Build the release binary**

```bash
stack build
```

- [ ] **Step 2: Verify all commands**

```bash
stack exec claudespaces -- --help
stack exec claudespaces -- list
```

Expected: help text shows `new`, `start`, `stop`, `rm`, `remove`, `ls`, `list`. List shows existing workspaces from `~/.claudespaces/workspaces.json` (compatible with Python-created state).

- [ ] **Step 3: Test creating a workspace (requires Docker)**

```bash
mkdir -p /tmp/test-claudespaces-proj
stack exec claudespaces -- new /tmp/test-claudespaces-proj --named test-hs
stack exec claudespaces -- list
stack exec claudespaces -- remove test-hs
rmdir /tmp/test-claudespaces-proj
```

Expected: workspace created, listed, removed. State file compatible with prior Python-created workspaces.

- [ ] **Step 4: Run full test suite one final time**

```bash
stack test
```

Expected: all tests pass.

- [ ] **Step 5: Commit any final fixes**

```bash
git add -A
git commit -m "chore: final adjustments after smoke testing"
```
