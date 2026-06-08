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
  deriving (Show, Eq)

instance Exception AppError

displayError :: AppError -> String
displayError (ConfigError msg)              = "Config error: " <> T.unpack msg
displayError (WorkspaceNotFound name)       = "Workspace '" <> T.unpack name <> "' not found"
displayError (WorkspaceAlreadyExists name)  = "Workspace '" <> T.unpack name <> "' already exists"
displayError (WorkspaceAlreadyRunning name) = "Workspace '" <> T.unpack name <> "' is already running"
displayError (WorkspaceAlreadyStopped name) = "Workspace '" <> T.unpack name <> "' is already stopped"
displayError DockerNotReachable             = "Docker is not running or not reachable"
displayError (DockerBuildFailed msg)        = "Docker build failed: " <> T.unpack msg
displayError (DockerfileNotFound path)      = "Dockerfile not found: " <> path
displayError (BasenameCollision name)       = "Basename collision: multiple directories share the basename '" <> name <> "'"
displayError (MountOverlap targets)         = "Overlapping container mount targets: " <> T.unpack (T.intercalate ", " targets)
displayError (InvalidMount msg)             = "Invalid mount: " <> T.unpack msg
displayError NameGenerationFailed           = "Could not generate a unique workspace name"
displayError HomeNotSet                     = "HOME environment variable not set"
