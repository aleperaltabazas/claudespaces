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
