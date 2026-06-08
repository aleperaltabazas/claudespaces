{-# LANGUAGE OverloadedStrings #-}

module Claudespaces.Config
  ( Config (..)
  , MountEntry (..)
  , emptyConfig
  , loadConfig
  , parseMount
  ) where

import           Control.Exception  (throwIO)
import           System.IO.Error    (userError)
import           Data.Aeson         (FromJSON (..), withObject, (.:?))
import           Data.List          (nub)
import qualified Data.Set           as Set
import           Data.Text          (Text)
import qualified Data.Text          as T
import           Data.Yaml          (decodeFileThrow, decodeThrow)
import qualified Data.ByteString    as BS
import           System.Directory   (doesFileExist)
import           System.FilePath    ((</>))

-- ---------------------------------------------------------------------------
-- Public types
-- ---------------------------------------------------------------------------

data MountEntry = MountEntry
  { mountSource   :: Text
  , mountTarget   :: Text
  , mountReadOnly :: Bool
  } deriving (Eq, Show)

data Config = Config
  { cfgImage            :: Maybe Text
  , cfgDockerfile       :: Maybe Text
  , cfgGlobalDockerfile :: Maybe Text
  , cfgDirectories      :: [Text]
  , cfgAdditionalMounts :: [MountEntry]
  } deriving (Eq, Show)

emptyConfig :: Config
emptyConfig = Config
  { cfgImage            = Nothing
  , cfgDockerfile       = Nothing
  , cfgGlobalDockerfile = Nothing
  , cfgDirectories      = []
  , cfgAdditionalMounts = []
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
      , rawDirectories      = maybe [] id dirs
      , rawAdditionalMounts = maybe [] id mounts
      }

-- ---------------------------------------------------------------------------
-- parseMount
-- ---------------------------------------------------------------------------

parseMount :: Text -> Either Text MountEntry
parseMount raw =
  case T.splitOn ":" raw of
    [src, dst] ->
      Right $ MountEntry src dst False
    [src, dst, mode] ->
      case mode of
        "ro" -> Right $ MountEntry src dst True
        "rw" -> Right $ MountEntry src dst False
        _    -> Left $ "Invalid mount mode: " <> mode
    _ ->
      Left $ "Invalid mount entry (expected src:dst or src:dst:ro|rw): " <> raw

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

validate :: String -> RawConfig -> IO ()
validate label rc =
  case (rawImage rc, rawDockerfile rc) of
    (Just _, Just _) ->
      throwIO $ userError $
        label <> ": cannot specify both 'image' and 'dockerfile'"
    _ -> return ()

parseMounts :: [Text] -> IO [MountEntry]
parseMounts entries =
  mapM parseSingle entries
  where
    parseSingle t =
      case parseMount t of
        Right m  -> return m
        Left err -> throwIO $ userError $ T.unpack err

checkOverlap :: [MountEntry] -> [MountEntry] -> IO ()
checkOverlap globalMounts localMounts = do
  let globalTargets = Set.fromList (map mountTarget globalMounts)
      localTargets  = Set.fromList (map mountTarget localMounts)
      overlap       = Set.intersection globalTargets localTargets
  if Set.null overlap
    then return ()
    else throwIO $ userError $
           "Overlapping container mount targets between global and local config: "
           <> T.unpack (T.intercalate ", " (Set.toList overlap))

-- ---------------------------------------------------------------------------
-- loadConfig
-- ---------------------------------------------------------------------------

loadConfig :: FilePath -> FilePath -> IO Config
loadConfig cwd globalPath = do
  -- Load both files
  global <- loadYaml globalPath
  local  <- loadYaml (cwd </> "claudespaces.yml")

  -- Validate mutual exclusion in each file
  validate "global config" global
  validate "local config"  local

  -- Parse mounts
  globalMounts <- parseMounts (rawAdditionalMounts global)
  localMounts  <- parseMounts (rawAdditionalMounts local)

  -- Check for overlapping container targets
  checkOverlap globalMounts localMounts

  -- Merge image: local overrides global
  let mergedImage = case rawImage local of
        Just _  -> rawImage local
        Nothing -> rawImage global

  -- Directories: global ++ local, deduplicated
  let mergedDirs = nub (rawDirectories global ++ rawDirectories local)

  -- Mounts: global ++ local
  let mergedMounts = globalMounts ++ localMounts

  return Config
    { cfgImage            = mergedImage
    , cfgDockerfile       = rawDockerfile local
    , cfgGlobalDockerfile = rawDockerfile global
    , cfgDirectories      = mergedDirs
    , cfgAdditionalMounts = mergedMounts
    }
