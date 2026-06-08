{-# LANGUAGE OverloadedStrings #-}

module Claudespaces.HostConfig
  ( Operation (..)
  , BridgeConfig (..)
  , defaultPort
  , builtinOperations
  , loadHostBridge
  , overridesManifest
  , writeShims
  , defaultShimsPath
  ) where

import           Control.Exception     (catch, SomeException)
import           Data.Aeson            (FromJSON (..), ToJSON (..), encode,
                                        withObject, (.:), (.:?), (.!=))
import qualified Data.Aeson            as Aeson
import qualified Data.ByteString.Lazy  as BL
import           Data.Map.Strict       (Map)
import qualified Data.Map.Strict       as Map
import           Data.Text             (Text)
import           Data.Yaml             (decodeFileThrow)
import           System.Directory      (createDirectoryIfMissing,
                                        doesFileExist, getHomeDirectory)
import           System.FilePath       ((</>), takeDirectory)

-- ---------------------------------------------------------------------------
-- Public types
-- ---------------------------------------------------------------------------

data Operation = Operation
  { opCommand  :: Text
  , opArgs     :: [Text]
  , opAsync    :: Bool
  , opOverride :: Maybe Text
  } deriving (Eq, Show)

data BridgeConfig = BridgeConfig
  { bridgePort       :: Int
  , bridgeOperations :: Map Text Operation
  } deriving (Eq, Show)

defaultPort :: Int
defaultPort = 7731

-- ---------------------------------------------------------------------------
-- Builtin operations
-- ---------------------------------------------------------------------------

builtinOperations :: Map Text Operation
builtinOperations = Map.fromList
  [ ("notify", Operation "notify-send {summary} {body}" ["summary", "body"] True (Just "notify-send"))
  ]

-- ---------------------------------------------------------------------------
-- JSON instances
-- ---------------------------------------------------------------------------

instance FromJSON Operation where
  parseJSON = withObject "Operation" $ \o -> do
    cmd      <- o .:  "command"
    args     <- o .:? "args"     .!= []
    async_   <- o .:? "async"    .!= False
    override <- o .:? "override"
    return $ Operation cmd args async_ override

instance ToJSON Operation where
  toJSON op = Aeson.object
    [ "command"  Aeson..= opCommand op
    , "args"     Aeson..= opArgs op
    , "async"    Aeson..= opAsync op
    , "override" Aeson..= opOverride op
    ]

-- ---------------------------------------------------------------------------
-- Internal raw YAML types
-- ---------------------------------------------------------------------------

data RawBridgeYaml = RawBridgeYaml
  { rawBridgePort :: Maybe Int
  , rawBridgeOps  :: Maybe (Map Text Operation)
  }

instance FromJSON RawBridgeYaml where
  parseJSON = withObject "RawBridgeYaml" $ \o -> do
    port <- o .:? "port"
    ops  <- o .:? "operations"
    return $ RawBridgeYaml port ops

data RawGlobalYaml = RawGlobalYaml
  { rawHostBridge :: Maybe RawBridgeYaml
  }

instance FromJSON RawGlobalYaml where
  parseJSON = withObject "RawGlobalYaml" $ \o -> do
    bridge <- o .:? "host_bridge"
    return $ RawGlobalYaml bridge

-- ---------------------------------------------------------------------------
-- loadHostBridge
-- ---------------------------------------------------------------------------

loadHostBridge :: FilePath -> IO BridgeConfig
loadHostBridge path = do
  exists <- doesFileExist path
  if not exists
    then return $ BridgeConfig defaultPort builtinOperations
    else do
      raw <- decodeFileThrow path :: IO RawGlobalYaml
      case rawHostBridge raw of
        Nothing ->
          return $ BridgeConfig defaultPort builtinOperations
        Just bridge -> do
          let port     = maybe defaultPort id (rawBridgePort bridge)
              userOps  = maybe Map.empty id (rawBridgeOps bridge)
              -- user wins on conflict: union prefers left operand
              mergedOps = Map.union userOps builtinOperations
          return $ BridgeConfig port mergedOps

-- ---------------------------------------------------------------------------
-- overridesManifest
-- ---------------------------------------------------------------------------

-- Returns {override_binary: op_name} for ops that have an override field
overridesManifest :: Map Text Operation -> Map Text Text
overridesManifest ops =
  Map.foldrWithKey collectOverride Map.empty ops
  where
    collectOverride opName op acc =
      case opOverride op of
        Nothing       -> acc
        Just binary   -> Map.insert binary opName acc

-- ---------------------------------------------------------------------------
-- writeShims
-- ---------------------------------------------------------------------------

writeShims :: FilePath -> Map Text Operation -> IO ()
writeShims path ops = do
  createDirectoryIfMissing True (takeDirectory path)
  let manifest = overridesManifest ops
  BL.writeFile path (encode manifest)

-- ---------------------------------------------------------------------------
-- defaultShimsPath
-- ---------------------------------------------------------------------------

defaultShimsPath :: IO FilePath
defaultShimsPath = do
  home <- getHomeDirectory
  return $ home </> ".claudespaces" </> "shims.json"
