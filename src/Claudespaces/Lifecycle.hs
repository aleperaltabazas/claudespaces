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

import Claudespaces.Container   (getRunningContainerIds, attachContainer, stopContainer)
import Claudespaces.Env         (App, Env (..))
import Claudespaces.Error       (AppError (..))
import Claudespaces.HostServer  (isRunning, startServer, stopServerIfLast)
import Claudespaces.Workspaces  (Status (..), Workspace (..), healRunning, updateWorkspace)

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
        updateWorkspace sf wsName (\w -> w { status = Stopped, lastUsedAt = now })
        stopContainer cid
        stopServerIfLast wsName sf
