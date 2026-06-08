{-# LANGUAGE OverloadedStrings #-}

module Claudespaces.Workspaces
  ( Workspace (..)
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
  , adjectives
  , nouns
  ) where

import           Control.Exception       (ioError)
import           Data.Aeson              (FromJSON (..), ToJSON (..), Value (..),
                                          object, withObject, (.:), (.=))
import qualified Data.Aeson              as Aeson
import qualified Data.Aeson.KeyMap       as KM
import qualified Data.Aeson.Key          as Key
import qualified Data.ByteString.Lazy    as BL
import           Data.Set                (Set)
import qualified Data.Set                as Set
import           Data.Text               (Text)
import qualified Data.Text               as T
import           System.Directory        (createDirectoryIfMissing,
                                          doesFileExist)
import           System.FilePath         (takeDirectory, (</>))
import           System.IO.Error         (userError)
import           System.Random           (randomRIO)
import           System.Environment      (lookupEnv)

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

data Workspace = Workspace
  { wsName        :: Text
  , wsDirs        :: [Text]
  , wsContainerId :: Text
  , wsImage       :: Text
  , wsCreatedAt   :: Text
  , wsLastUsedAt  :: Text
  , wsStatus      :: Text
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

instance ToJSON Workspace where
  toJSON ws = object
    [ "name"         .= wsName        ws
    , "dirs"         .= wsDirs        ws
    , "container_id" .= wsContainerId ws
    , "image"        .= wsImage       ws
    , "created_at"   .= wsCreatedAt   ws
    , "last_used_at" .= wsLastUsedAt  ws
    , "status"       .= wsStatus      ws
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
        Right ws -> return ws
        Left err -> ioError (userError $ "Failed to parse " <> path <> ": " <> err)
    else do
      migrated <- tryMigrate path
      case migrated of
        Just ws -> return ws
        Nothing -> return []

-- | Attempt to migrate from sessions.json in the same directory as the state file.
tryMigrate :: FilePath -> IO (Maybe [Workspace])
tryMigrate statePath = do
  let sessionsPath = takeDirectory statePath </> "sessions.json"
  exists <- doesFileExist sessionsPath
  if not exists
    then return Nothing
    else do
      bs <- BL.readFile sessionsPath
      case Aeson.eitherDecode bs :: Either String [Value] of
        Left _      -> return Nothing
        Right vals  -> do
          let stripped = map dropId vals
          case mapM Aeson.fromJSON stripped of
            Aeson.Error _   -> return Nothing
            Aeson.Success ws -> do
              save statePath ws
              return (Just ws)

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
getByName path name = do
  ws <- load path
  return $ case filter (\w -> wsName w == name) ws of
    (x:_) -> Just x
    []    -> Nothing

nameExists :: FilePath -> Text -> IO Bool
nameExists path name = do
  result <- getByName path name
  return $ case result of
    Just _  -> True
    Nothing -> False

saveWorkspace :: FilePath -> Workspace -> IO ()
saveWorkspace path ws = do
  existing <- load path
  save path (existing ++ [ws])

updateWorkspace :: FilePath -> Text -> (Workspace -> Workspace) -> IO ()
updateWorkspace path name f = do
  ws <- load path
  let (matched, others) = foldr partition' ([], []) ws
  case matched of
    []    -> ioError (userError $ "Workspace not found: " <> T.unpack name)
    (x:_) -> save path (others ++ [f x])
  where
    partition' w (ms, os)
      | wsName w == name = (w : ms, os)
      | otherwise        = (ms, w : os)

removeWorkspace :: FilePath -> Text -> IO ()
removeWorkspace path name = do
  ws <- load path
  save path (filter (\w -> wsName w /= name) ws)

-- | Mark any workspace whose status is "running" but whose container_id is
--   not in the provided running set as "stopped".
healRunning :: FilePath -> Set Text -> IO ()
healRunning path running = do
  ws <- load path
  let healed = map heal ws
  save path healed
  where
    heal w
      | wsStatus w == "running" && not (Set.member (wsContainerId w) running) =
          w { wsStatus = "stopped" }
      | otherwise = w

-- | Generate a random adjective-noun name that is not in the taken set.
generateName :: Set Text -> IO Text
generateName taken = go (10000 :: Int)
  where
    go 0 = ioError (userError "Could not generate a unique workspace name")
    go n = do
      ai <- randomRIO (0, length adjectives - 1)
      ni <- randomRIO (0, length nouns - 1)
      let name = (adjectives !! ai) <> "-" <> (nouns !! ni)
      if Set.member name taken
        then go (n - 1)
        else return name

-- | Return the state directory for a given state file path and a sub-path.
stateDir :: FilePath -> Text -> FilePath
stateDir base sub = takeDirectory base </> T.unpack sub

-- | Default state file path: ~/.claudespaces/workspaces.json
defaultStateFile :: IO FilePath
defaultStateFile = do
  home <- lookupEnv "HOME"
  case home of
    Just h  -> return $ h </> ".claudespaces" </> "workspaces.json"
    Nothing -> ioError (userError "HOME environment variable not set")

-- ---------------------------------------------------------------------------
-- Word lists
-- ---------------------------------------------------------------------------

adjectives :: [Text]
adjectives =
  [ "bold", "calm", "dark", "deep", "fast", "free", "hard", "high"
  , "kind", "last", "late", "long", "loud", "mild", "near", "next"
  , "nice", "open", "pure", "rare", "real", "rich", "safe", "slim"
  , "slow", "soft", "tall", "thin", "tiny", "vast", "warm", "wide"
  , "wild", "wise", "blue", "cold", "cool", "dull", "fair", "firm"
  , "flat", "full", "gray", "keen", "lazy", "lean", "live", "lost"
  , "mad",  "neat"
  ]

nouns :: [Text]
nouns =
  [ "space", "orbit", "comet", "cloud", "creek", "delta", "drift"
  , "dusk",  "echo",  "field", "flame", "flare", "flash", "flow"
  , "forge", "frost", "glade", "gleam", "grove", "haven", "haze"
  , "isle",  "lake",  "leap",  "light", "lodge", "loom",  "lunar"
  , "marsh", "mist",  "moon",  "moss",  "nova",  "ocean", "peak"
  , "plain", "prism", "pulse", "ridge", "rift",  "river", "rock"
  , "shade", "shore", "sky",   "slope", "snow",  "solar", "spark"
  , "star",  "stone"
  ]
