
module Claudespaces.Workspaces
  ( Workspace (..)
  , Status (..)
  , allWorkspaces
  , getByName
  , nameExists
  , saveWorkspace
  , updateWorkspace
  , removeWorkspace
  , healRunning
  , generateName
  , stateDir
  , defaultStateFile
  ) where

import           Control.Exception               (throwIO)
import           Data.Aeson                      (FromJSON (..), ToJSON (..), Value (..),
                                                  object, withObject, (.:), (.:?), (.!=), (.=))
import qualified Data.Aeson                      as Aeson
import qualified Data.Aeson.KeyMap               as KM
import qualified Data.Aeson.Key                  as Key
import qualified Data.ByteString.Lazy            as BL
import           Data.Maybe                      (isJust)
import           Data.Set                        (Set)
import qualified Data.Set                        as Set
import           Data.Text                       (Text)
import qualified Data.Text                       as T
import           System.Directory                (createDirectoryIfMissing,
                                                  doesFileExist)
import           System.FilePath                 (takeDirectory, (</>))
import           System.Random                   (randomRIO)
import           System.Environment              (lookupEnv)

import           Claudespaces.Config             (Mount)
import           Claudespaces.Error              (AppError (..))
import           Claudespaces.Workspaces.Internal (adjectives, nouns)

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

data Status = Running | Stopped deriving (Eq, Show)

instance FromJSON Status where
  parseJSON = Aeson.withText "Status" $ \t -> case t of
    "running" -> pure Running
    "stopped" -> pure Stopped
    other     -> fail $ "Unknown status: " <> T.unpack other

instance ToJSON Status where
  toJSON Running = Aeson.String "running"
  toJSON Stopped = Aeson.String "stopped"

data Workspace = Workspace
  { name        :: Text
  , dirs        :: [Text]
  , containerId :: Text
  , image       :: Text
  , createdAt   :: Text
  , lastUsedAt  :: Text
  , status      :: Status
  , mounts      :: [Mount]
  } deriving (Eq, Show)

instance FromJSON Workspace where
  parseJSON = withObject "Workspace" $ \o ->
    Workspace
      <$> o .: "name"
      <*> o .: "dirs"
      <*> o .: "container_id"
      <*> o .: "image"
      <*> o .: "created_at"
      <*> o .: "last_used_at"
      <*> o .: "status"
      <*> o .:? "mounts" .!= []

instance ToJSON Workspace where
  toJSON ws = object
    [ "name"         .= ws.name
    , "dirs"         .= ws.dirs
    , "container_id" .= ws.containerId
    , "image"        .= ws.image
    , "created_at"   .= ws.createdAt
    , "last_used_at" .= ws.lastUsedAt
    , "status"       .= ws.status
    , "mounts"       .= ws.mounts
    ]

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

-- | Load workspaces from file; tries migration from sessions.json if absent.
load :: FilePath -> IO [Workspace]
load path = do
  exists <- doesFileExist path
  if exists
    then do
      bs <- BL.readFile path
      case Aeson.eitherDecode bs of
        Right ws  -> pure ws
        Left err  -> throwIO (ConfigError (T.pack $ "Failed to parse " <> path <> ": " <> err))
    else do
      migrated <- tryMigrate path
      case migrated of
        Just ws -> pure ws
        Nothing -> pure []

-- | Attempt to migrate from sessions.json in the same directory as the state file.
tryMigrate :: FilePath -> IO (Maybe [Workspace])
tryMigrate statePath = do
  let sessionsPath = takeDirectory statePath </> "sessions.json"
  exists <- doesFileExist sessionsPath
  if not exists
    then pure Nothing
    else do
      bs <- BL.readFile sessionsPath
      case Aeson.eitherDecode bs :: Either String [Value] of
        Left _      -> pure Nothing
        Right vals  -> do
          let stripped = map dropId vals
          case mapM Aeson.fromJSON stripped of
            Aeson.Error _    -> pure Nothing
            Aeson.Success ws -> do
              save statePath ws
              pure (Just ws)

-- | Drop the "id" key from a JSON object (noop for non-objects).
dropId :: Value -> Value
dropId (Object o) = Object (KM.delete (Key.fromString "id") o)
dropId v          = v

-- | Write the workspace list to disk (creating parent dirs as needed).
save :: FilePath -> [Workspace] -> IO ()
save path ws = do
  createDirectoryIfMissing True (takeDirectory path)
  BL.writeFile path (Aeson.encode ws)

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

allWorkspaces :: FilePath -> IO [Workspace]
allWorkspaces = load

getByName :: FilePath -> Text -> IO (Maybe Workspace)
getByName path n = do
  ws <- load path
  pure $ case filter (\w -> w.name == n) ws of
    (x:_) -> Just x
    []    -> Nothing

nameExists :: FilePath -> Text -> IO Bool
nameExists path n = isJust <$> getByName path n

saveWorkspace :: FilePath -> Workspace -> IO ()
saveWorkspace path ws = do
  existing <- load path
  save path (existing ++ [ws])

updateWorkspace :: FilePath -> Text -> (Workspace -> Workspace) -> IO ()
updateWorkspace path n f = do
  ws <- load path
  let matched = filter (\w -> w.name == n) ws
      others  = filter (\w -> w.name /= n) ws
  case matched of
    []    -> throwIO (WorkspaceNotFound n)
    (x:_) -> save path (others ++ [f x])

removeWorkspace :: FilePath -> Text -> IO ()
removeWorkspace path n = do
  ws <- load path
  save path (filter (\w -> w.name /= n) ws)

-- | Mark any workspace whose status is Running but whose containerId is
--   not in the provided running set as Stopped.
healRunning :: FilePath -> Set Text -> IO ()
healRunning path running = do
  ws <- load path
  let healed = map heal ws
  save path healed
  where
    heal w
      | w.status == Running && not (Set.member w.containerId running) =
          w { status = Stopped }
      | otherwise = w

-- | Generate a random adjective-noun name that is not in the taken set.
generateName :: Set Text -> IO Text
generateName taken = go (10000 :: Int)
  where
    go 0 = throwIO NameGenerationFailed
    go n = do
      ai <- randomRIO (0, length adjectives - 1)
      ni <- randomRIO (0, length nouns - 1)
      let candidate = (adjectives !! ai) <> "-" <> (nouns !! ni)
      if Set.member candidate taken
        then go (n - 1)
        else pure candidate

-- | Return the state directory for a given state file path and a sub-path.
stateDir :: FilePath -> Text -> FilePath
stateDir base sub = takeDirectory base </> T.unpack sub

-- | Default state file path: ~/.claudespaces/workspaces.json
defaultStateFile :: IO FilePath
defaultStateFile = do
  home <- lookupEnv "HOME"
  case home of
    Just h  -> pure $ h </> ".claudespaces" </> "workspaces.json"
    Nothing -> throwIO HomeNotSet
