# Rebuild Subcommand Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `rebuild` subcommand that re-resolves the Docker image and recreates the container for an existing workspace, preserving claudespaces state.

**Architecture:** Single-file change in `Cli.hs`. Add `RebuildOpts` type, `rebuildCommand` parser, `cmdRebuild` handler, wire into `Command` ADT and `dispatch`. Follows the same pattern as existing subcommands.

**Tech Stack:** Haskell, optparse-applicative, existing modules (Config, Container, Image, Workspaces, Lifecycle, Support)

---

### Task 1: Add `RebuildOpts` type and `Rebuild` constructor to `Command`

**Files:**
- Modify: `src/Claudespaces/Cli.hs:43-56`

- [ ] **Step 1: Add `RebuildOpts` and `Rebuild` to the ADT**

In `src/Claudespaces/Cli.hs`, add the `Rebuild` constructor to `Command` and the `RebuildOpts` record after `NewOpts`:

```haskell
data Command
  = New NewOpts
  | Start Text
  | Stop Text
  | Remove Text
  | List
  | Rebuild RebuildOpts

data NewOpts = NewOpts
  { dirs       :: [String]
  , named      :: Maybe Text
  , start      :: Bool
  , image      :: Maybe Text
  , dockerfile :: Maybe String
  }

data RebuildOpts = RebuildOpts
  { name       :: Text
  , image      :: Maybe Text
  , dockerfile :: Maybe String
  , start      :: Bool
  }
```

- [ ] **Step 2: Add dispatch case**

In the `dispatch` function at the bottom of `Cli.hs`, add the `Rebuild` case:

```haskell
dispatch :: Command -> App ()
dispatch (New    newOpts) = cmdNew newOpts
dispatch (Start  name)    = cmdStart name
dispatch (Stop   name)    = cmdStop name
dispatch (Remove name)    = cmdRemove name
dispatch List             = cmdList
dispatch (Rebuild opts)   = cmdRebuild opts
```

- [ ] **Step 3: Verify it compiles (will fail — `cmdRebuild` not yet defined)**

Run: `stack build 2>&1 | tail -5`
Expected: compile error mentioning `cmdRebuild` not in scope — confirms wiring is correct.

---

### Task 2: Add `rebuildCommand` parser

**Files:**
- Modify: `src/Claudespaces/Cli.hs:62-110`

- [ ] **Step 1: Add the parser function**

Add `rebuildCommand` after `removeCommand` in the parsers section:

```haskell
rebuildCommand :: Parser Command
rebuildCommand = fmap Rebuild $ RebuildOpts
  <$> (T.pack <$> argument str (metavar "NAME"))
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
  <*> switch
        ( long "start"
       <> short 's'
       <> help "Start the workspace after rebuild"
        )
```

- [ ] **Step 2: Register in the subparser block**

Add to the `commandParser` subparser list:

```haskell
 <> command "rebuild" (info (rebuildCommand <**> helper) (progDesc "Rebuild a workspace image and container"))
```

- [ ] **Step 3: Verify it compiles (will still fail — `cmdRebuild` not yet defined)**

Run: `stack build 2>&1 | tail -5`
Expected: compile error mentioning `cmdRebuild` not in scope.

---

### Task 3: Implement `cmdRebuild`

**Files:**
- Modify: `src/Claudespaces/Cli.hs` (new section after `cmdRemove`)

- [ ] **Step 1: Add the `cmdRebuild` function**

Add between the `cmdRemove` and `cmdList` sections:

```haskell
-- ---------------------------------------------------------------------------
-- cmdRebuild
-- ---------------------------------------------------------------------------

cmdRebuild :: RebuildOpts -> App ()
cmdRebuild opts = do
  home           <- asks (.home)
  globalCfgPath  <- asks (.globalConfigPath)
  sf             <- asks (.stateFile)
  shimsPath      <- asks (.shimsPath)

  (wsName, cid, port) <- liftIO $ do
    -- Load workspace
    ws <- requireWorkspace sf opts.name

    -- Check docker is reachable
    checkDocker

    -- Heal stale workspaces
    runningIds <- Container.getRunningContainerIds
    Workspaces.healRunning sf runningIds

    -- Reload after heal, check not running
    ws2 <- requireWorkspace sf opts.name
    when (ws2.status == Running) $ throwIO (WorkspaceAlreadyRunning opts.name)

    -- Load config
    cfg <- Config.loadConfig "." globalCfgPath

    -- Determine image/dockerfile: CLI flags > config > defaults
    let mImage      = case opts.image of
          Just i  -> Just i
          Nothing -> cfg.image
    let mDockerfile = case opts.dockerfile of
          Just d  -> Just d
          Nothing -> fmap T.unpack cfg.dockerfile
    let mGlobalDockerfile = fmap T.unpack cfg.globalDockerfile

    -- Resolve image (full chain)
    image' <- withSupportDir $ \supportDir ->
      Image.resolveImage mImage mGlobalDockerfile mDockerfile supportDir

    -- Remove old container
    Container.removeContainer ws2.containerId

    -- Build mounts and create new container
    let wsDirs = map T.unpack ws2.dirs
    either throwIO pure (Container.checkBasenameCollision wsDirs)

    -- Load bridge config, write shims
    bridgeCfg <- HostConfig.loadHostBridge globalCfgPath
    let port = bridgeCfg.port
    HostConfig.writeShims shimsPath bridgeCfg.operations

    let wsd     = Workspaces.stateDir sf opts.name
    let mounts  = Container.buildMounts wsDirs wsd port cfg.additionalMounts home
    hostMounts <- Container.resolveHostMounts home
    let envVars = Container.buildEnv port home
    cid <- Container.createContainer image' (mounts ++ hostMounts) envVars

    -- Update workspace record
    now <- nowUtc
    Workspaces.updateWorkspace sf opts.name (\w -> w
      { containerId = cid
      , image       = image'
      , lastUsedAt  = now
      })

    putStrLn $ "Rebuilt workspace: " <> T.unpack opts.name
    pure (opts.name, cid, port)

  -- If --start, attach
  when opts.start $
    attachWithCleanup wsName cid port
```

- [ ] **Step 2: Build and verify compilation**

Run: `stack build 2>&1 | tail -5`
Expected: successful build with no errors.

- [ ] **Step 3: Verify CLI help shows rebuild**

Run: `stack exec claudespaces -- --help`
Expected: `rebuild` appears in the list of available commands.

Run: `stack exec claudespaces -- rebuild --help`
Expected: shows NAME positional arg plus `--image`, `--dockerfile`, `--start` flags.

- [ ] **Step 4: Commit**

```bash
git add src/Claudespaces/Cli.hs
git commit -m "feat: add rebuild subcommand"
```
