
module Claudespaces.Config
  ( Config (..)
  , Mount (..)
  , emptyConfig
  , loadConfig
  , parseMount
  ) where

import           Control.Applicative ((<|>))
import           Control.Exception  (throwIO)
import           Data.Aeson         (FromJSON (..), withObject, (.:?))
import           Data.List          (nub)
import           Data.Maybe         (fromMaybe)
import qualified Data.Set           as Set
import           Data.Text          (Text)
import qualified Data.Text          as T
import           Data.Yaml          (decodeThrow)
import qualified Data.ByteString    as BS
import           System.Directory   (doesFileExist)
import           System.FilePath    ((</>))

import           Claudespaces.Error (AppError (..))

-- ---------------------------------------------------------------------------
-- Public types
-- ---------------------------------------------------------------------------

data Mount = Mount
  { source   :: Text
  , target   :: Text
  , readOnly :: Bool
  } deriving (Eq, Show)

data Config = Config
  { image            :: Maybe Text
  , dockerfile       :: Maybe Text
  , globalDockerfile :: Maybe Text
  , directories      :: [Text]
  , additionalMounts :: [Mount]
  } deriving (Eq, Show)

emptyConfig :: Config
emptyConfig = Config
  { image            = Nothing
  , dockerfile       = Nothing
  , globalDockerfile = Nothing
  , directories      = []
  , additionalMounts = []
  }

-- ---------------------------------------------------------------------------
-- Internal raw config (parsed directly from YAML)
-- ---------------------------------------------------------------------------

data RawConfig = RawConfig
  { image            :: Maybe Text
  , dockerfile       :: Maybe Text
  , directories      :: [Text]
  , additionalMounts :: [Text]
  } deriving (Eq, Show)

emptyRaw :: RawConfig
emptyRaw = RawConfig Nothing Nothing [] []

instance FromJSON RawConfig where
  parseJSON = withObject "RawConfig" $ \o -> do
    img   <- o .:? "image"
    df    <- o .:? "dockerfile"
    dirs  <- o .:? "directories"
    mounts <- o .:? "additional-mounts"
    pure $ RawConfig
      { image            = img
      , dockerfile       = df
      , directories      = fromMaybe [] dirs
      , additionalMounts = fromMaybe [] mounts
      }

-- ---------------------------------------------------------------------------
-- parseMount
-- ---------------------------------------------------------------------------

parseMount :: Text -> Either AppError Mount
parseMount raw =
  case T.splitOn ":" raw of
    [src, dst] ->
      Right $ Mount src dst False
    [src, dst, mode] ->
      case mode of
        "ro" -> Right $ Mount src dst True
        "rw" -> Right $ Mount src dst False
        _    -> Left $ InvalidMount $ "Invalid mount mode: " <> mode
    _ ->
      Left $ InvalidMount $ "Invalid mount entry (expected src:dst or src:dst:ro|rw): " <> raw

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

loadYaml :: FilePath -> IO RawConfig
loadYaml path = do
  exists <- doesFileExist path
  if not exists
    then pure emptyRaw
    else do
      bs <- BS.readFile path
      if BS.null bs
        then pure emptyRaw
        else decodeThrow bs

validate :: String -> RawConfig -> Either AppError ()
validate label rc =
  case (rc.image, rc.dockerfile) of
    (Just _, Just _) ->
      Left $ ConfigError $ T.pack $
        label <> ": cannot specify both 'image' and 'dockerfile'"
    _ -> Right ()

parseMounts :: [Text] -> Either AppError [Mount]
parseMounts = traverse parseMount

checkOverlap :: [Mount] -> [Mount] -> Either AppError ()
checkOverlap globalMounts localMounts =
  let globalTargets = Set.fromList (map (.target) globalMounts)
      localTargets  = Set.fromList (map (.target) localMounts)
      overlap       = Set.intersection globalTargets localTargets
  in if Set.null overlap
       then Right ()
       else Left $ MountOverlap (Set.toList overlap)

-- ---------------------------------------------------------------------------
-- loadConfig
-- ---------------------------------------------------------------------------

loadConfig :: FilePath -> FilePath -> IO Config
loadConfig cwd globalPath = do
  -- Load both files
  global <- loadYaml globalPath
  local  <- loadYaml (cwd </> "claudespaces.yml")

  -- Validate mutual exclusion in each file
  either throwIO pure $ validate "global config" global
  either throwIO pure $ validate "local config"  local

  -- Parse mounts
  globalMounts <- either throwIO pure $ parseMounts global.additionalMounts
  localMounts  <- either throwIO pure $ parseMounts local.additionalMounts

  -- Check for overlapping container targets
  either throwIO pure $ checkOverlap globalMounts localMounts

  -- Merge image: local overrides global
  let mergedImage = local.image <|> global.image

  -- Directories: global ++ local, deduplicated
  let mergedDirs = nub (global.directories ++ local.directories)

  -- Mounts: global ++ local
  let mergedMounts = globalMounts ++ localMounts

  pure Config
    { image            = mergedImage
    , dockerfile       = local.dockerfile
    , globalDockerfile = global.dockerfile
    , directories      = mergedDirs
    , additionalMounts = mergedMounts
    }
