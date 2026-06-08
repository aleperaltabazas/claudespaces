
module Claudespaces.Cli (run) where

import           Control.Exception          (SomeException, catch, finally, try)
import           Data.List                  (intercalate, nub, sortBy)
import           Data.Map.Strict            (Map)
import qualified Data.Map.Strict            as Map
import qualified Data.Set                   as Set
import           Data.Text                  (Text)
import qualified Data.Text                  as T
import           Data.Time.Clock            (getCurrentTime)
import           Data.Time.Format.ISO8601   (iso8601Show)
import           Options.Applicative
import           System.Directory           ( canonicalizePath
                                            , createDirectoryIfMissing
                                            , doesDirectoryExist
                                            , doesFileExist
                                            , copyFile
                                            , getHomeDirectory
                                            )
import           System.Exit                (ExitCode (..), exitFailure)
import           System.FilePath            ((</>), takeDirectory)
import           System.Process             (readProcessWithExitCode)

import qualified Claudespaces.Config        as Config
import qualified Claudespaces.Container     as Container
import qualified Claudespaces.HostConfig    as HostConfig
import qualified Claudespaces.HostServer    as HostServer
import qualified Claudespaces.Image         as Image
import qualified Claudespaces.Workspaces    as Workspaces

-- ---------------------------------------------------------------------------
-- CLI data types
-- ---------------------------------------------------------------------------

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

-- ---------------------------------------------------------------------------
-- Parsers
-- ---------------------------------------------------------------------------

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

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

nowUtc :: IO Text
nowUtc = T.pack . iso8601Show <$> getCurrentTime

checkDocker :: IO Bool
checkDocker = do
  (code, _, _) <- readProcessWithExitCode "docker" ["info"] ""
  return $ code == ExitSuccess

startBridge :: Int -> IO ()
startBridge port = do
  running <- HostServer.isRunning port
  if running
    then return ()
    else HostServer.startServer

collapseHome :: FilePath -> FilePath -> String
collapseHome home path =
  case stripPrefix' (home ++ "/") path of
    Just rest -> "~/" ++ rest
    Nothing   -> path
  where
    stripPrefix' pre s
      | take (length pre) s == pre = Just (drop (length pre) s)
      | otherwise                  = Nothing

-- ---------------------------------------------------------------------------
-- cmdNew
-- ---------------------------------------------------------------------------

cmdNew :: NewOpts -> IO ()
cmdNew opts = do
  home <- getHomeDirectory
  let globalConfigPath = home </> ".config" </> "claudespaces" </> "claudespaces.yaml"

  cfg <- Config.loadConfig "." globalConfigPath

  sf <- Workspaces.defaultStateFile

  -- Check --named uniqueness
  case newNamed opts of
    Just n -> do
      exists <- Workspaces.nameExists sf n
      if exists
        then do
          putStrLn $ "Error: workspace '" <> T.unpack n <> "' already exists"
          exitFailure
        else return ()
    Nothing -> return ()

  -- Determine image / dockerfile from CLI + config
  let mImage      = case newImage opts of
        Just i  -> Just i
        Nothing -> Config.cfgImage cfg
  let mDockerfile = case newDockerfile opts of
        Just d  -> Just d
        Nothing -> fmap T.unpack (Config.cfgDockerfile cfg)
  let mGlobalDockerfile = fmap T.unpack (Config.cfgGlobalDockerfile cfg)

  -- Check docker is reachable
  ok <- checkDocker
  if not ok
    then do
      putStrLn "Error: Docker is not reachable. Is the daemon running?"
      exitFailure
    else return ()

  -- Merge CLI dirs with config dirs, resolve, deduplicate
  let configDirs = map T.unpack (Config.cfgDirectories cfg)
  let rawDirs    = nub (newDirs opts ++ configDirs)
  resolvedDirs <- mapM canonicalizePath rawDirs
  mapM_ (\d -> do
    ex <- doesDirectoryExist d
    if not ex
      then do
        putStrLn $ "Error: directory does not exist: " <> d
        exitFailure
      else return ()
    ) resolvedDirs

  -- Resolve image
  image <- Image.resolveImage mImage mGlobalDockerfile mDockerfile "support"

  -- Heal stale workspaces
  runningIds <- Container.getRunningContainerIds
  Workspaces.healRunning sf runningIds

  -- Generate workspace name
  allWs <- Workspaces.allWorkspaces sf
  let takenNames = Set.fromList (map Workspaces.wsName allWs)
  wsName <- case newNamed opts of
    Just n  -> return n
    Nothing -> Workspaces.generateName takenNames

  -- Create state dir
  let wsd = Workspaces.stateDir sf wsName
  createDirectoryIfMissing True (wsd </> "projects")

  -- Copy ~/.claude.json if exists
  let claudeJsonSrc = home </> ".claude.json"
  let claudeJsonDst = wsd </> "claude.json"
  srcExists <- doesFileExist claudeJsonSrc
  if srcExists
    then copyFile claudeJsonSrc claudeJsonDst
    else return ()

  -- Load host bridge config, write shims
  bridgeCfg <- HostConfig.loadHostBridge globalConfigPath
  let port = HostConfig.bridgePort bridgeCfg
  shimsPath <- HostConfig.defaultShimsPath
  HostConfig.writeShims shimsPath (HostConfig.bridgeOperations bridgeCfg)

  -- Check basename collisions
  Container.checkBasenameCollision resolvedDirs

  -- Build mounts and create container
  let mounts  = Container.buildMounts resolvedDirs wsd port (Config.cfgAdditionalMounts cfg) home
  hostMounts <- Container.resolveHostMounts home
  let envVars = Container.buildEnv port home
  cid <- Container.createContainer image (mounts ++ hostMounts) envVars

  -- Save workspace
  now <- nowUtc
  let ws = Workspaces.Workspace
        { Workspaces.wsName        = wsName
        , Workspaces.wsDirs        = map T.pack resolvedDirs
        , Workspaces.wsContainerId = cid
        , Workspaces.wsImage       = image
        , Workspaces.wsCreatedAt   = now
        , Workspaces.wsLastUsedAt  = now
        , Workspaces.wsStatus      = "stopped"
        }
  Workspaces.saveWorkspace sf ws

  putStrLn $ "Created workspace: " <> T.unpack wsName

  -- If --start, attach
  if newStart opts
    then do
      startBridge port
      Workspaces.updateWorkspace sf wsName (\w -> w { Workspaces.wsStatus = "running" })
      Container.attachContainer cid
        `finally` do
          now2 <- nowUtc
          Workspaces.updateWorkspace sf wsName (\w -> w
            { Workspaces.wsStatus      = "stopped"
            , Workspaces.wsLastUsedAt  = now2
            })
          Container.stopContainer cid
          HostServer.stopServerIfLast wsName sf
    else return ()

-- ---------------------------------------------------------------------------
-- cmdStart
-- ---------------------------------------------------------------------------

cmdStart :: Text -> IO ()
cmdStart name = do
  home <- getHomeDirectory
  let globalConfigPath = home </> ".config" </> "claudespaces" </> "claudespaces.yaml"
  sf <- Workspaces.defaultStateFile

  mws <- Workspaces.getByName sf name
  ws  <- case mws of
    Nothing -> do
      putStrLn $ "Error: workspace '" <> T.unpack name <> "' not found"
      exitFailure
    Just w  -> return w

  ok <- checkDocker
  if not ok
    then do
      putStrLn "Error: Docker is not reachable. Is the daemon running?"
      exitFailure
    else return ()

  -- Heal stale workspaces
  runningIds <- Container.getRunningContainerIds
  Workspaces.healRunning sf runningIds

  -- Reload workspace after heal
  mws2 <- Workspaces.getByName sf name
  ws2  <- case mws2 of
    Nothing -> do
      putStrLn $ "Error: workspace '" <> T.unpack name <> "' not found"
      exitFailure
    Just w  -> return w

  if Workspaces.wsStatus ws2 == "running"
    then do
      putStrLn $ "Workspace '" <> T.unpack name <> "' is already running"
      exitFailure
    else return ()

  -- Load bridge config, write shims
  bridgeCfg <- HostConfig.loadHostBridge globalConfigPath
  let port = HostConfig.bridgePort bridgeCfg
  shimsPath <- HostConfig.defaultShimsPath
  HostConfig.writeShims shimsPath (HostConfig.bridgeOperations bridgeCfg)

  -- If state dir doesn't exist, recreate it and recreate the container
  let wsd = Workspaces.stateDir sf name
  wsdExists <- doesDirectoryExist wsd
  cid <- if wsdExists
    then return (Workspaces.wsContainerId ws2)
    else do
      -- Migration path: recreate state dir and container
      createDirectoryIfMissing True (wsd </> "projects")
      let claudeJsonSrc = home </> ".claude.json"
      let claudeJsonDst = wsd </> "claude.json"
      srcExists <- doesFileExist claudeJsonSrc
      if srcExists then copyFile claudeJsonSrc claudeJsonDst else return ()
      -- Load config to get mounts/image
      cfg    <- Config.loadConfig "." globalConfigPath
      let dirs = map T.unpack (Workspaces.wsDirs ws2)
      let mounts  = Container.buildMounts dirs wsd port (Config.cfgAdditionalMounts cfg) home
      hostMounts' <- Container.resolveHostMounts home
      let envVars = Container.buildEnv port home
      newCid <- Container.createContainer (Workspaces.wsImage ws2) (mounts ++ hostMounts') envVars
      Workspaces.updateWorkspace sf name (\w -> w { Workspaces.wsContainerId = newCid })
      return newCid

  -- Start bridge, set running, attach
  startBridge port
  Workspaces.updateWorkspace sf name (\w -> w { Workspaces.wsStatus = "running" })
  Container.attachContainer cid
    `finally` do
      now <- nowUtc
      Workspaces.updateWorkspace sf name (\w -> w
        { Workspaces.wsStatus     = "stopped"
        , Workspaces.wsLastUsedAt = now
        })
      Container.stopContainer cid
      HostServer.stopServerIfLast name sf

-- ---------------------------------------------------------------------------
-- cmdStop
-- ---------------------------------------------------------------------------

cmdStop :: Text -> IO ()
cmdStop name = do
  sf  <- Workspaces.defaultStateFile
  mws <- Workspaces.getByName sf name
  ws  <- case mws of
    Nothing -> do
      putStrLn $ "Error: workspace '" <> T.unpack name <> "' not found"
      exitFailure
    Just w  -> return w

  if Workspaces.wsStatus ws == "stopped"
    then do
      putStrLn $ "Workspace '" <> T.unpack name <> "' is already stopped"
      return ()
    else do
      Container.stopContainer (Workspaces.wsContainerId ws)
      now <- nowUtc
      Workspaces.updateWorkspace sf name (\w -> w
        { Workspaces.wsStatus     = "stopped"
        , Workspaces.wsLastUsedAt = now
        })
      HostServer.stopServerIfLast name sf
      putStrLn $ "Stopped workspace: " <> T.unpack name

-- ---------------------------------------------------------------------------
-- cmdRemove
-- ---------------------------------------------------------------------------

cmdRemove :: Text -> IO ()
cmdRemove name = do
  sf  <- Workspaces.defaultStateFile
  mws <- Workspaces.getByName sf name
  ws  <- case mws of
    Nothing -> do
      putStrLn $ "Error: workspace '" <> T.unpack name <> "' not found"
      exitFailure
    Just w  -> return w

  let wasRunning = Workspaces.wsStatus ws == "running"
  Container.removeContainer (Workspaces.wsContainerId ws)
  Workspaces.removeWorkspace sf name
  if wasRunning then HostServer.stopServerIfLast name sf else return ()
  -- Remove state dir
  let wsd = Workspaces.stateDir sf name
  removeDir wsd
  putStrLn $ "Removed workspace: " <> T.unpack name
  where
    removeDir dir = do
      exists <- doesDirectoryExist dir
      if exists
        then do
          (code, _, _) <- readProcessWithExitCode "rm" ["-rf", dir] ""
          case code of
            ExitSuccess   -> return ()
            ExitFailure _ -> putStrLn $ "Warning: could not remove state dir: " <> dir
        else return ()

-- ---------------------------------------------------------------------------
-- cmdList
-- ---------------------------------------------------------------------------

cmdList :: IO ()
cmdList = do
  sf <- Workspaces.defaultStateFile
  home <- getHomeDirectory
  ws   <- Workspaces.allWorkspaces sf
  let sorted = sortBy (\a b -> compare (Workspaces.wsLastUsedAt b) (Workspaces.wsLastUsedAt a)) ws
  let nameHdr   = "NAME"
      statusHdr = "STATUS"
      dirsHdr   = "DIRS"
      lastHdr   = "LAST USED"
  let rows = map (\w ->
        ( T.unpack (Workspaces.wsName w)
        , T.unpack (Workspaces.wsStatus w)
        , intercalate ", " (map (collapseHome home . T.unpack) (Workspaces.wsDirs w))
        , T.unpack (Workspaces.wsLastUsedAt w)
        )) sorted
  let nameW   = maximum (map (\(n,_,_,_) -> length n) rows ++ [length nameHdr])
      statusW  = maximum (map (\(_,s,_,_) -> length s) rows ++ [length statusHdr])
      dirsW    = maximum (map (\(_,_,d,_) -> length d) rows ++ [length dirsHdr])
  let pad n s = s ++ replicate (n - length s) ' '
  let printRow (n, s, d, l) = putStrLn $
        pad nameW n <> "  " <> pad statusW s <> "  " <> pad dirsW d <> "  " <> l
  putStrLn $ pad nameW nameHdr <> "  " <> pad statusW statusHdr <> "  " <> pad dirsW dirsHdr <> "  " <> lastHdr
  putStrLn $ replicate (nameW + 2 + statusW + 2 + dirsW + 2 + length lastHdr) '-'
  mapM_ printRow rows

-- ---------------------------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------------------------

run :: IO ()
run = do
  cmd <- execParser opts
  case cmd of
    New    newOpts -> cmdNew newOpts
    Start  name   -> cmdStart name
    Stop   name   -> cmdStop name
    Remove name   -> cmdRemove name
    List          -> cmdList
  where
    opts = info (commandParser <**> helper)
      ( fullDesc
     <> progDesc "Manage Claude Code workspaces in Docker containers"
     <> header "claudespaces - workspace manager"
      )
