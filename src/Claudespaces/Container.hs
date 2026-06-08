{-# LANGUAGE OverloadedStrings #-}

module Claudespaces.Container
  ( MountSpec (..)
  , checkBasenameCollision
  , buildMounts
  , buildEnv
  , mountSpecToArgs
  , createContainer
  , attachContainer
  , getRunningContainerIds
  , stopContainer
  , removeContainer
  ) where

import           Control.Exception      (throwIO)
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

import           Claudespaces.Config    (MountEntry (..))

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

buildMounts :: [FilePath] -> FilePath -> Int -> [MountEntry] -> FilePath -> [MountSpec]
buildMounts dirs stateDir _hostPort additionalMounts _homePath =
  userMounts ++ stateMounts ++ extraMounts
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

    extraMounts =
      [ MountSpec
          { mSource   = mountSource m
          , mTarget   = mountTarget m
          , mReadOnly = mountReadOnly m
          }
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
  out <- readProcess "docker" ["ps", "-q", "--filter", "status=running"] ""
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
