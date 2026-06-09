
module Claudespaces.Cli (run) where

import           Control.Exception          (catch, throwIO)
import           Control.Monad              (unless, when)
import           Control.Monad.IO.Class     (liftIO)
import           Control.Monad.Reader       (asks, runReaderT)
import           Data.List                  (intercalate, nub, sortBy)
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
                                            )
import           System.Exit                (ExitCode (..), exitFailure)
import           System.FilePath            ((</>))
import           System.IO                  (hPutStrLn, stderr)
import           System.Process             (readProcessWithExitCode)

import qualified Claudespaces.Config        as Config
import qualified Claudespaces.Container     as Container
import qualified Claudespaces.HostConfig    as HostConfig
import qualified Claudespaces.HostServer    as HostServer
import qualified Claudespaces.Image         as Image
import qualified Claudespaces.Workspaces    as Workspaces

import           Claudespaces.Env           (App, Env (..), mkEnv)
import           Claudespaces.Error         (AppError (..), displayError)
import           Claudespaces.Lifecycle     (attachWithCleanup, checkDocker, healStaleWorkspaces)
import           Claudespaces.Workspaces    (Status (..), Workspace (..))

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
  { dirs       :: [String]
  , named      :: Maybe Text
  , start      :: Bool
  , image      :: Maybe Text
  , dockerfile :: Maybe String
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

collapseHome :: FilePath -> FilePath -> String
collapseHome home path =
  case stripPrefix' (home ++ "/") path of
    Just rest -> "~/" ++ rest
    Nothing   -> path
  where
    stripPrefix' pre s
      | take (length pre) s == pre = Just (drop (length pre) s)
      | otherwise                  = Nothing

statusText :: Status -> String
statusText Running = "running"
statusText Stopped = "stopped"

requireWorkspace :: FilePath -> Text -> IO Workspace
requireWorkspace sf n = do
  mws <- Workspaces.getByName sf n
  case mws of
    Nothing -> throwIO (WorkspaceNotFound n)
    Just w  -> pure w

-- ---------------------------------------------------------------------------
-- cmdNew
-- ---------------------------------------------------------------------------

cmdNew :: NewOpts -> App ()
cmdNew opts = do
  home           <- asks (.home)
  globalCfgPath  <- asks (.globalConfigPath)
  sf             <- asks (.stateFile)
  shimsPath      <- asks (.shimsPath)

  (wsName, cid, port) <- liftIO $ do
    cfg <- Config.loadConfig "." globalCfgPath

    -- Check --named uniqueness
    case opts.named of
      Just n -> do
        exists <- Workspaces.nameExists sf n
        when exists $ throwIO (WorkspaceAlreadyExists n)
      Nothing -> pure ()

    -- Determine image / dockerfile from CLI + config
    let mImage      = case opts.image of
          Just i  -> Just i
          Nothing -> cfg.image
    let mDockerfile = case opts.dockerfile of
          Just d  -> Just d
          Nothing -> fmap T.unpack cfg.dockerfile
    let mGlobalDockerfile = fmap T.unpack cfg.globalDockerfile

    -- Check docker is reachable
    checkDocker

    -- Merge CLI dirs with config dirs, resolve, deduplicate
    let configDirs = map T.unpack cfg.directories
    let rawDirs    = nub (opts.dirs ++ configDirs)
    resolvedDirs <- mapM canonicalizePath rawDirs
    mapM_ (\d -> do
      ex <- doesDirectoryExist d
      unless ex $ throwIO (ConfigError (T.pack $ "directory does not exist: " <> d))
      ) resolvedDirs

    -- Resolve image
    image' <- Image.resolveImage mImage mGlobalDockerfile mDockerfile "support"

    -- Heal stale workspaces
    runningIds <- Container.getRunningContainerIds
    Workspaces.healRunning sf runningIds

    -- Generate workspace name
    allWs <- Workspaces.allWorkspaces sf
    let takenNames = Set.fromList (map (.name) allWs)
    wsName <- case opts.named of
      Just n  -> pure n
      Nothing -> Workspaces.generateName takenNames

    -- Create state dir
    let wsd = Workspaces.stateDir sf wsName
    createDirectoryIfMissing True (wsd </> "projects")

    -- Copy ~/.claude.json if exists
    let claudeJsonSrc = home </> ".claude.json"
    let claudeJsonDst = wsd </> "claude.json"
    srcExists <- doesFileExist claudeJsonSrc
    when srcExists $ copyFile claudeJsonSrc claudeJsonDst

    -- Load host bridge config, write shims
    bridgeCfg <- HostConfig.loadHostBridge globalCfgPath
    let port = bridgeCfg.port
    HostConfig.writeShims shimsPath bridgeCfg.operations

    -- Check basename collisions
    either throwIO pure (Container.checkBasenameCollision resolvedDirs)

    -- Build mounts and create container
    let mounts  = Container.buildMounts resolvedDirs wsd port cfg.additionalMounts home
    hostMounts <- Container.resolveHostMounts home
    let envVars = Container.buildEnv port home
    cid <- Container.createContainer image' (mounts ++ hostMounts) envVars

    -- Save workspace
    now <- nowUtc
    let ws = Workspace
          { name        = wsName
          , dirs        = map T.pack resolvedDirs
          , containerId = cid
          , image       = image'
          , createdAt   = now
          , lastUsedAt  = now
          , status      = Stopped
          }
    Workspaces.saveWorkspace sf ws

    putStrLn $ "Created workspace: " <> T.unpack wsName
    pure (wsName, cid, port)

  -- If --start, attach
  when opts.start $
    attachWithCleanup wsName cid port

-- ---------------------------------------------------------------------------
-- cmdStart
-- ---------------------------------------------------------------------------

cmdStart :: Text -> App ()
cmdStart name = do
  home           <- asks (.home)
  globalCfgPath  <- asks (.globalConfigPath)
  sf             <- asks (.stateFile)
  shimsPath      <- asks (.shimsPath)

  (cid, port) <- liftIO $ do
    _ <- requireWorkspace sf name

    -- Check docker is reachable
    checkDocker

    -- Heal stale workspaces
    runningIds <- Container.getRunningContainerIds
    Workspaces.healRunning sf runningIds

    -- Reload workspace after heal
    ws2 <- requireWorkspace sf name

    when (ws2.status == Running) $ throwIO (WorkspaceAlreadyRunning name)

    -- Load bridge config, write shims
    bridgeCfg <- HostConfig.loadHostBridge globalCfgPath
    let port = bridgeCfg.port
    HostConfig.writeShims shimsPath bridgeCfg.operations

    -- If state dir doesn't exist, recreate it and recreate the container
    let wsd = Workspaces.stateDir sf name
    wsdExists <- doesDirectoryExist wsd
    cid <- if wsdExists
      then pure ws2.containerId
      else do
        -- Migration path: recreate state dir and container
        createDirectoryIfMissing True (wsd </> "projects")
        let claudeJsonSrc = home </> ".claude.json"
        let claudeJsonDst = wsd </> "claude.json"
        srcExists <- doesFileExist claudeJsonSrc
        when srcExists $ copyFile claudeJsonSrc claudeJsonDst
        -- Load config to get mounts/image
        cfg    <- Config.loadConfig "." globalCfgPath
        let wsDirs = map T.unpack ws2.dirs
        let mounts  = Container.buildMounts wsDirs wsd port cfg.additionalMounts home
        hostMounts' <- Container.resolveHostMounts home
        let envVars = Container.buildEnv port home
        newCid <- Container.createContainer ws2.image (mounts ++ hostMounts') envVars
        Workspaces.updateWorkspace sf name (\w -> w { containerId = newCid })
        pure newCid

    pure (cid, port)

  attachWithCleanup name cid port

-- ---------------------------------------------------------------------------
-- cmdStop
-- ---------------------------------------------------------------------------

cmdStop :: Text -> App ()
cmdStop name = do
  sf <- asks (.stateFile)
  liftIO $ do
    ws <- requireWorkspace sf name

    when (ws.status == Stopped) $ throwIO (WorkspaceAlreadyStopped name)

    Container.stopContainer ws.containerId
    now <- nowUtc
    Workspaces.updateWorkspace sf name (\w -> w
      { status     = Stopped
      , lastUsedAt = now
      })
    HostServer.stopServerIfLast name sf
    putStrLn $ "Stopped workspace: " <> T.unpack name

-- ---------------------------------------------------------------------------
-- cmdRemove
-- ---------------------------------------------------------------------------

cmdRemove :: Text -> App ()
cmdRemove name = do
  sf <- asks (.stateFile)
  liftIO $ do
    ws <- requireWorkspace sf name

    let wasRunning = ws.status == Running
    Container.removeContainer ws.containerId
    Workspaces.removeWorkspace sf name
    when wasRunning $ HostServer.stopServerIfLast name sf
    -- Remove state dir
    let wsd = Workspaces.stateDir sf name
    removeDir wsd
    putStrLn $ "Removed workspace: " <> T.unpack name
  where
    removeDir dir = do
      exists <- doesDirectoryExist dir
      when exists $ do
        (code, _, _) <- readProcessWithExitCode "rm" ["-rf", dir] ""
        case code of
          ExitSuccess   -> pure ()
          ExitFailure _ -> putStrLn $ "Warning: could not remove state dir: " <> dir

-- ---------------------------------------------------------------------------
-- cmdList
-- ---------------------------------------------------------------------------

cmdList :: App ()
cmdList = do
  sf   <- asks (.stateFile)
  home <- asks (.home)
  liftIO $ do
    ws   <- Workspaces.allWorkspaces sf
    let sorted = sortBy (\a b -> compare b.lastUsedAt a.lastUsedAt) ws
    let nameHdr   = "NAME"
        statusHdr = "STATUS"
        dirsHdr   = "DIRS"
        lastHdr   = "LAST USED"
    let rows = map (\w ->
          ( T.unpack w.name
          , statusText w.status
          , intercalate ", " (map (collapseHome home . T.unpack) w.dirs)
          , T.unpack w.lastUsedAt
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

dispatch :: Command -> App ()
dispatch (New    newOpts) = cmdNew newOpts
dispatch (Start  name)    = cmdStart name
dispatch (Stop   name)    = cmdStop name
dispatch (Remove name)    = cmdRemove name
dispatch List             = cmdList

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
