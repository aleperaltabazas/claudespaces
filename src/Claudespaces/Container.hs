
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

import           Control.Monad          (void)
import           System.Directory       (doesFileExist, doesDirectoryExist)
import           Data.List              (group, sort)
import qualified Data.Set               as Set
import           Data.Set               (Set)
import           Data.Text              (Text)
import qualified Data.Text              as T
import           System.Exit            (ExitCode (..))
import           System.FilePath        (takeBaseName, (</>))
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
import           Claudespaces.Error     (AppError (..))

-- ---------------------------------------------------------------------------
-- Pure functions
-- ---------------------------------------------------------------------------

checkBasenameCollision :: [FilePath] -> Either AppError ()
checkBasenameCollision dirs =
  let basenames = map takeBaseName dirs
      dups = map head . filter ((> 1) . length) . group . sort $ basenames
  in case dups of
    []    -> pure ()
    (d:_) -> Left (BasenameCollision d)

buildMounts :: [FilePath] -> FilePath -> Int -> [Mount] -> FilePath -> [Mount]
buildMounts dirs stateDir _hostPort additionalMounts homePath =
  userMounts ++ stateMounts ++ hostMounts ++ additionalMounts
  where
    userMounts =
      [ Mount
          { source   = T.pack d
          , target   = T.pack $ "/workspace/" <> takeBaseName d
          , readOnly = False
          }
      | d <- dirs
      ]

    stateMounts =
      [ Mount
          { source   = T.pack (stateDir </> "claude.json")
          , target   = "/root/.claude.json"
          , readOnly = False
          }
      , Mount
          { source   = T.pack (stateDir </> "projects")
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

-- | Host paths to mount read-only into the container if they exist on the host.
hostClaudePaths :: FilePath -> [(FilePath, String)]
hostClaudePaths homePath =
  [ (homePath </> ".claude" </> "settings.json", "/claudespaces/host/settings.json")
  , (homePath </> ".claude" </> "plugins",       "/claudespaces/host/plugins")
  , (homePath </> ".claude" </> "credentials.json", "/claudespaces/host/credentials.json")
  ]

resolveHostMounts :: FilePath -> IO [Mount]
resolveHostMounts homePath = do
  let paths = hostClaudePaths homePath
  fmap concat $ mapM checkAndMount paths
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

-- ---------------------------------------------------------------------------
-- IO wrappers (not tested — thin shell-outs)
-- ---------------------------------------------------------------------------

createContainer :: Text -> [Mount] -> [(String, String)] -> IO Text
createContainer image mounts envVars = do
  let mountArgs = concatMap mountToArgs mounts
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
  pure . T.strip . T.pack $ out

attachContainer :: Text -> IO ()
attachContainer containerId = do
  let cid = T.unpack containerId
  void $ readProcess "docker" ["start", cid] ""
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
  void $ waitForProcess ph

getRunningContainerIds :: IO (Set Text)
getRunningContainerIds = do
  out <- readProcess "docker" ["ps", "-q", "--no-trunc", "--filter", "status=running"] ""
  let ids = filter (not . T.null) . map T.strip . T.lines . T.pack $ out
  pure $ Set.fromList ids

stopContainer :: Text -> IO ()
stopContainer containerId =
  void $ readProcess "docker" ["stop", T.unpack containerId] ""

removeContainer :: Text -> IO ()
removeContainer containerId = do
  (_, _, _, ph) <- createProcess
    (proc "docker" ["rm", "-f", T.unpack containerId])
    { std_in  = Inherit
    , std_out = Inherit
    , std_err = Inherit
    }
  void $ waitForProcess ph
