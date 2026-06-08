
module Claudespaces.Container
  ( MountSpec (..)
  , checkBasenameCollision
  , buildMounts
  , hostClaudePaths
  , resolveHostMounts
  , buildEnv
  , mountSpecToArgs
  , createContainer
  , attachContainer
  , getRunningContainerIds
  , stopContainer
  , removeContainer
  ) where

import           Control.Exception      (throwIO)
import           System.Directory       (doesFileExist, doesDirectoryExist)
import           Data.List              (group, sort)
import qualified Data.Set               as Set
import           Data.Set               (Set)
import           Data.Text              (Text)
import qualified Data.Text              as T
import           System.Exit            (ExitCode (..))
import           System.FilePath        (takeBaseName, (</>))
import           System.IO.Error        (userError)
import           System.Process         ( createProcess
                                        , proc
                                        , readProcess
                                        , StdStream (..)
                                        , std_in
                                        , std_out
                                        , std_err
                                        , delegate_ctlc
                                        , waitForProcess
                                        )

import           Claudespaces.Config    (Mount (..))

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

data MountSpec = MountSpec
  { mSource   :: Text
  , mTarget   :: Text
  , mReadOnly :: Bool
  } deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- Pure functions
-- ---------------------------------------------------------------------------

checkBasenameCollision :: [FilePath] -> IO ()
checkBasenameCollision dirs = do
  let basenames = map takeBaseName dirs
      dups = map head . filter ((> 1) . length) . group . sort $ basenames
  case dups of
    [] -> return ()
    (d:_) -> throwIO $ userError $
      "Basename collision: multiple directories share the basename '" <> d <> "'"

buildMounts :: [FilePath] -> FilePath -> Int -> [Mount] -> FilePath -> [MountSpec]
buildMounts dirs stateDir _hostPort additionalMounts homePath =
  userMounts ++ stateMounts ++ hostMounts ++ extraMounts
  where
    userMounts =
      [ MountSpec
          { mSource   = T.pack d
          , mTarget   = T.pack $ "/workspace/" <> takeBaseName d
          , mReadOnly = False
          }
      | d <- dirs
      ]

    stateMounts =
      [ MountSpec
          { mSource   = T.pack (stateDir </> "claude.json")
          , mTarget   = "/root/.claude.json"
          , mReadOnly = False
          }
      , MountSpec
          { mSource   = T.pack (stateDir </> "projects")
          , mTarget   = "/root/.claude/projects"
          , mReadOnly = False
          }
      ]

    hostMounts =
      [ MountSpec
          { mSource   = T.pack (homePath </> ".claudespaces" </> "shims.json")
          , mTarget   = "/claudespaces/shims.json"
          , mReadOnly = True
          }
      ]

    extraMounts =
      [ MountSpec
          { mSource   = m.source
          , mTarget   = m.target
          , mReadOnly = m.readOnly
          }
      | m <- additionalMounts
      ]

-- | Host paths to mount read-only into the container if they exist on the host.
hostClaudePaths :: FilePath -> [(FilePath, String)]
hostClaudePaths homePath =
  [ (homePath </> ".claude" </> "settings.json", "/claudespaces/host/settings.json")
  , (homePath </> ".claude" </> "plugins",       "/claudespaces/host/plugins")
  , (homePath </> ".claude" </> "credentials.json", "/claudespaces/host/credentials.json")
  ]

resolveHostMounts :: FilePath -> IO [MountSpec]
resolveHostMounts homePath = do
  let paths = hostClaudePaths homePath
  fmap concat $ mapM checkAndMount paths
  where
    checkAndMount (src, tgt) = do
      fileExists <- doesFileExist src
      dirExists  <- doesDirectoryExist src
      if fileExists || dirExists
        then return [MountSpec (T.pack src) (T.pack tgt) True]
        else return []

buildEnv :: Int -> FilePath -> [(String, String)]
buildEnv hostPort homePath =
  [ ("IS_SANDBOX", "1")
  , ("HOST_HOME", homePath)
  , ("CLAUDESPACES_HOST_PORT", show hostPort)
  ]

mountSpecToArgs :: MountSpec -> [String]
mountSpecToArgs m =
  [ "--mount"
  , "type=bind,source=" ++ T.unpack (mSource m)
      ++ ",target=" ++ T.unpack (mTarget m)
      ++ if mReadOnly m then ",readonly" else ""
  ]

-- ---------------------------------------------------------------------------
-- IO wrappers (not tested — thin shell-outs)
-- ---------------------------------------------------------------------------

createContainer :: Text -> [MountSpec] -> [(String, String)] -> IO Text
createContainer image mounts envVars = do
  let mountArgs = concatMap mountSpecToArgs mounts
      envArgs   = concatMap (\(k, v) -> ["-e", k <> "=" <> v]) envVars
      args      = [ "create", "--tty", "--interactive"
                  , "--user", "root"
                  , "-w", "/workspace"
                  , "--add-host", "host.docker.internal:host-gateway"
                  ]
                  ++ mountArgs
                  ++ envArgs
                  ++ [T.unpack image]
  out <- readProcess "docker" args ""
  return . T.strip . T.pack $ out

attachContainer :: Text -> IO ()
attachContainer containerId = do
  let cid = T.unpack containerId
  _ <- readProcess "docker" ["start", cid] ""
  (_, _, _, ph) <- createProcess
    (proc "docker"
      [ "exec", "-it"
      , "-e", "TERM=xterm-256color"
      , cid
      , "/claudespaces/entrypoint.sh"
      ])
    { std_in  = Inherit
    , std_out = Inherit
    , std_err = Inherit
    , delegate_ctlc = True
    }
  _ <- waitForProcess ph
  return ()

getRunningContainerIds :: IO (Set Text)
getRunningContainerIds = do
  out <- readProcess "docker" ["ps", "-q", "--no-trunc", "--filter", "status=running"] ""
  let ids = filter (not . T.null) . map T.strip . T.lines . T.pack $ out
  return $ Set.fromList ids

stopContainer :: Text -> IO ()
stopContainer containerId = do
  _ <- readProcess "docker" ["stop", T.unpack containerId] ""
  return ()

removeContainer :: Text -> IO ()
removeContainer containerId = do
  (_, _, _, ph) <- createProcess
    (proc "docker" ["rm", "-f", T.unpack containerId])
    { std_in  = Inherit
    , std_out = Inherit
    , std_err = Inherit
    }
  _ <- waitForProcess ph
  return ()
