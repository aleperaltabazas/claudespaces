
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

import           Data.Aeson            (FromJSON (..), ToJSON (..), encode,
                                        withObject, (.:), (.:?), (.!=))
import qualified Data.Aeson            as Aeson
import qualified Data.ByteString.Lazy  as BL
import           Data.Map.Strict       (Map)
import qualified Data.Map.Strict       as Map
import           Data.Maybe            (fromMaybe)
import           Data.Text             (Text)
import           Data.Yaml             (decodeFileThrow)
import           System.Directory      (createDirectoryIfMissing,
                                        doesFileExist, getHomeDirectory)
import           System.FilePath       ((</>), takeDirectory)

-- ---------------------------------------------------------------------------
-- Public types
-- ---------------------------------------------------------------------------

data Operation = Operation
  { command  :: Text
  , args     :: [Text]
  , async    :: Bool
  , override :: Maybe Text
  } deriving (Eq, Show)

data BridgeConfig = BridgeConfig
  { port       :: Int
  , operations :: Map Text Operation
  } deriving (Eq, Show)

defaultPort :: Int
defaultPort = 7731

-- ---------------------------------------------------------------------------
-- Builtin operations
-- ---------------------------------------------------------------------------

builtinOperations :: Map Text Operation
builtinOperations = Map.fromList
  [ ("notify", Operation { command = "notify-send {summary} {body}", args = ["summary", "body"], async = True, override = Just "notify-send" })
  ]

-- ---------------------------------------------------------------------------
-- JSON instances
-- ---------------------------------------------------------------------------

instance FromJSON Operation where
  parseJSON = withObject "Operation" $ \o -> do
    cmd      <- o .:  "command"
    args_    <- o .:? "args"     .!= []
    async_   <- o .:? "async"    .!= False
    override_<- o .:? "override"
    pure $ Operation cmd args_ async_ override_

instance ToJSON Operation where
  toJSON op = Aeson.object
    [ "command"  Aeson..= op.command
    , "args"     Aeson..= op.args
    , "async"    Aeson..= op.async
    , "override" Aeson..= op.override
    ]

-- ---------------------------------------------------------------------------
-- Internal raw YAML types
-- ---------------------------------------------------------------------------

data RawBridgeYaml = RawBridgeYaml
  { port       :: Maybe Int
  , operations :: Maybe (Map Text Operation)
  }

instance FromJSON RawBridgeYaml where
  parseJSON = withObject "RawBridgeYaml" $ \o -> do
    p   <- o .:? "port"
    ops <- o .:? "operations"
    pure $ RawBridgeYaml p ops

data RawGlobalYaml = RawGlobalYaml
  { hostBridge :: Maybe RawBridgeYaml
  }

instance FromJSON RawGlobalYaml where
  parseJSON = withObject "RawGlobalYaml" $ \o -> do
    bridge <- o .:? "host_bridge"
    pure $ RawGlobalYaml bridge

-- ---------------------------------------------------------------------------
-- loadHostBridge
-- ---------------------------------------------------------------------------

loadHostBridge :: FilePath -> IO BridgeConfig
loadHostBridge path = do
  exists <- doesFileExist path
  if not exists
    then pure $ BridgeConfig defaultPort builtinOperations
    else do
      raw <- decodeFileThrow path :: IO RawGlobalYaml
      case raw.hostBridge of
        Nothing ->
          pure $ BridgeConfig defaultPort builtinOperations
        Just bridge -> do
          let p         = fromMaybe defaultPort bridge.port
              userOps   = fromMaybe Map.empty bridge.operations
              -- user wins on conflict: union prefers left operand
              mergedOps = Map.union userOps builtinOperations
          pure $ BridgeConfig p mergedOps

-- ---------------------------------------------------------------------------
-- overridesManifest
-- ---------------------------------------------------------------------------

-- Returns {override_binary: op_name} for ops that have an override field
overridesManifest :: Map Text Operation -> Map Text Text
overridesManifest ops =
  Map.foldrWithKey collectOverride Map.empty ops
  where
    collectOverride :: Text -> Operation -> Map Text Text -> Map Text Text
    collectOverride opName op acc =
      case op.override of
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
  pure $ home </> ".claudespaces" </> "shims.json"
