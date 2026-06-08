
module Claudespaces.Config
  ( Config (..)
  , Mount (..)
  , emptyConfig
  , loadConfig
  , parseMount
  ) where

import           Control.Exception  (throwIO)
import           Data.Aeson         (FromJSON (..), withObject, (.:?))
import           Data.List          (nub)
import qualified Data.Set           as Set
import           Data.Text          (Text)
import qualified Data.Text          as T
import           Data.Yaml          (decodeFileThrow, decodeThrow)
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
  { rawImage            :: Maybe Text
  , rawDockerfile       :: Maybe Text
  , rawDirectories      :: [Text]
  , rawAdditionalMounts :: [Text]
  } deriving (Eq, Show)

emptyRaw :: RawConfig
emptyRaw = RawConfig Nothing Nothing [] []

instance FromJSON RawConfig where
  parseJSON = withObject "RawConfig" $ \o -> do
    img   <- o .:? "image"
    df    <- o .:? "dockerfile"
    dirs  <- o .:? "directories"
    mounts <- o .:? "additional-mounts"
    return $ RawConfig
      { rawImage            = img
      , rawDockerfile       = df
      , rawDirectories      = fromMaybe [] dirs
      , rawAdditionalMounts = fromMaybe [] mounts
      }
    where
      fromMaybe d Nothing  = d
      fromMaybe _ (Just x) = x

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
    then return emptyRaw
    else do
      bs <- BS.readFile path
      if BS.null bs
        then return emptyRaw
        else decodeThrow bs

validate :: String -> RawConfig -> Either AppError ()
validate label rc =
  case (rawImage rc, rawDockerfile rc) of
    (Just _, Just _) ->
      Left $ ConfigError $ T.pack $
        label <> ": cannot specify both 'image' and 'dockerfile'"
    _ -> Right ()

parseMounts :: [Text] -> IO [Mount]
parseMounts entries =
  mapM parseSingle entries
  where
    parseSingle t =
      case parseMount t of
        Right m  -> return m
        Left err -> throwIO err

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
  globalMounts <- parseMounts (rawAdditionalMounts global)
  localMounts  <- parseMounts (rawAdditionalMounts local)

  -- Check for overlapping container targets
  either throwIO pure $ checkOverlap globalMounts localMounts

  -- Merge image: local overrides global
  let mergedImage = case rawImage local of
        Just _  -> rawImage local
        Nothing -> rawImage global

  -- Directories: global ++ local, deduplicated
  let mergedDirs = nub (rawDirectories global ++ rawDirectories local)

  -- Mounts: global ++ local
  let mergedMounts = globalMounts ++ localMounts

  return Config
    { image            = mergedImage
    , dockerfile       = rawDockerfile local
    , globalDockerfile = rawDockerfile global
    , directories      = mergedDirs
    , additionalMounts = mergedMounts
    }
