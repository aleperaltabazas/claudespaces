
module Claudespaces.WorkspacesSpec (spec) where

import           Test.Hspec
import           System.IO.Temp      (withSystemTempDirectory)
import qualified System.Directory
import           System.FilePath     ((</>))
import           Data.Text           (Text)
import qualified Data.Text           as T
import qualified Data.Set            as Set
import           Data.List           (sort)

import           Claudespaces.Config  (Mount (..))
import           Claudespaces.Workspaces
import           Claudespaces.Workspaces.Internal (adjectives, nouns)

-- | A minimal workspace for use in tests
sampleWorkspace :: Text -> Workspace
sampleWorkspace n = Workspace
  { name        = n
  , dirs        = ["/home/user/proj"]
  , containerId = "abc123"
  , image       = "ubuntu:24.04"
  , createdAt   = "2024-01-01T00:00:00"
  , lastUsedAt  = "2024-01-01T00:00:00"
  , status      = Stopped
  , mounts      = []
  }

spec :: Spec
spec = do
  describe "saveWorkspace / allWorkspaces" $ do
    it "saves and reads back a single workspace" $
      withSystemTempDirectory "ws" $ \dir -> do
        let f = dir </> "workspaces.json"
        let ws = sampleWorkspace "bold-comet"
        saveWorkspace f ws
        result <- allWorkspaces f
        result `shouldBe` [ws]

    it "allWorkspaces returns all saved workspaces" $
      withSystemTempDirectory "ws" $ \dir -> do
        let f = dir </> "workspaces.json"
        let ws1 = sampleWorkspace "bold-comet"
        let ws2 = sampleWorkspace "calm-river"
        saveWorkspace f ws1
        saveWorkspace f ws2
        result <- allWorkspaces f
        length result `shouldBe` 2

    it "multiple workspaces for the same dirs are allowed" $
      withSystemTempDirectory "ws" $ \dir -> do
        let f = dir </> "workspaces.json"
        let ws1 = (sampleWorkspace "bold-comet") { dirs = ["/home/user/proj"] }
        let ws2 = (sampleWorkspace "calm-river")  { dirs = ["/home/user/proj"] }
        saveWorkspace f ws1
        saveWorkspace f ws2
        result <- allWorkspaces f
        length result `shouldBe` 2

  describe "getByName" $ do
    it "finds a workspace by name" $
      withSystemTempDirectory "ws" $ \dir -> do
        let f = dir </> "workspaces.json"
        let ws = sampleWorkspace "bold-comet"
        saveWorkspace f ws
        result <- getByName f "bold-comet"
        result `shouldBe` Just ws

    it "returns Nothing when name not found" $
      withSystemTempDirectory "ws" $ \dir -> do
        let f = dir </> "workspaces.json"
        let ws = sampleWorkspace "bold-comet"
        saveWorkspace f ws
        result <- getByName f "no-such-name"
        result `shouldBe` Nothing

  describe "nameExists" $ do
    it "returns True when name exists" $
      withSystemTempDirectory "ws" $ \dir -> do
        let f = dir </> "workspaces.json"
        saveWorkspace f (sampleWorkspace "bold-comet")
        nameExists f "bold-comet" `shouldReturn` True

    it "returns False when name does not exist" $
      withSystemTempDirectory "ws" $ \dir -> do
        let f = dir </> "workspaces.json"
        saveWorkspace f (sampleWorkspace "bold-comet")
        nameExists f "no-such-name" `shouldReturn` False

  describe "updateWorkspace" $ do
    it "changes specified fields" $
      withSystemTempDirectory "ws" $ \dir -> do
        let f = dir </> "workspaces.json"
        saveWorkspace f (sampleWorkspace "bold-comet")
        updateWorkspace f "bold-comet" (\ws -> ws { status = Running })
        result <- getByName f "bold-comet"
        fmap (.status) result `shouldBe` Just Running

    it "leaves other fields intact" $
      withSystemTempDirectory "ws" $ \dir -> do
        let f = dir </> "workspaces.json"
        let ws = sampleWorkspace "bold-comet"
        saveWorkspace f ws
        updateWorkspace f "bold-comet" (\w -> w { status = Running })
        result <- getByName f "bold-comet"
        fmap (.image) result `shouldBe` Just "ubuntu:24.04"
        fmap (.dirs)  result `shouldBe` Just ["/home/user/proj"]

    it "raises when name not found" $
      withSystemTempDirectory "ws" $ \dir -> do
        let f = dir </> "workspaces.json"
        updateWorkspace f "no-such-name" id `shouldThrow` anyException

  describe "renameWorkspace" $ do
    it "renames an existing workspace" $
      withSystemTempDirectory "ws" $ \dir -> do
        let f = dir </> "workspaces.json"
        saveWorkspace f (sampleWorkspace "bold-comet")
        renameWorkspace f "bold-comet" "shiny-star"
        names <- map (.name) <$> allWorkspaces f
        names `shouldBe` ["shiny-star"]

    it "raises when old name not found" $
      withSystemTempDirectory "ws" $ \dir -> do
        let f = dir </> "workspaces.json"
        renameWorkspace f "no-such" "shiny-star" `shouldThrow` anyException

    it "raises when new name already taken" $
      withSystemTempDirectory "ws" $ \dir -> do
        let f = dir </> "workspaces.json"
        saveWorkspace f (sampleWorkspace "bold-comet")
        saveWorkspace f (sampleWorkspace "calm-river")
        renameWorkspace f "bold-comet" "calm-river" `shouldThrow` anyException

    it "renames the state directory if present" $
      withSystemTempDirectory "ws" $ \dir -> do
        let f = dir </> "workspaces.json"
        saveWorkspace f (sampleWorkspace "bold-comet")
        let oldDir = stateDir f "bold-comet"
            newDir = stateDir f "shiny-star"
        System.Directory.createDirectoryIfMissing True oldDir
        renameWorkspace f "bold-comet" "shiny-star"
        oldExists <- System.Directory.doesDirectoryExist oldDir
        newExists <- System.Directory.doesDirectoryExist newDir
        oldExists `shouldBe` False
        newExists `shouldBe` True

  describe "removeWorkspace" $ do
    it "removes the correct record" $
      withSystemTempDirectory "ws" $ \dir -> do
        let f = dir </> "workspaces.json"
        saveWorkspace f (sampleWorkspace "bold-comet")
        saveWorkspace f (sampleWorkspace "calm-river")
        removeWorkspace f "bold-comet"
        result <- allWorkspaces f
        map (.name) result `shouldBe` ["calm-river"]

  describe "healRunning" $ do
    it "marks stale running workspaces as stopped" $
      withSystemTempDirectory "ws" $ \dir -> do
        let f = dir </> "workspaces.json"
        let ws = (sampleWorkspace "bold-comet") { status = Running, containerId = "stale123" }
        saveWorkspace f ws
        healRunning f (Set.fromList [])
        result <- getByName f "bold-comet"
        fmap (.status) result `shouldBe` Just Stopped

    it "leaves actually running workspaces unchanged" $
      withSystemTempDirectory "ws" $ \dir -> do
        let f = dir </> "workspaces.json"
        let ws = (sampleWorkspace "bold-comet") { status = Running, containerId = "live123" }
        saveWorkspace f ws
        healRunning f (Set.fromList ["live123"])
        result <- getByName f "bold-comet"
        fmap (.status) result `shouldBe` Just Running

    it "leaves stopped workspaces unchanged" $
      withSystemTempDirectory "ws" $ \dir -> do
        let f = dir </> "workspaces.json"
        let ws = (sampleWorkspace "bold-comet") { status = Stopped, containerId = "abc123" }
        saveWorkspace f ws
        healRunning f (Set.fromList [])
        result <- getByName f "bold-comet"
        fmap (.status) result `shouldBe` Just Stopped

    it "only changes stale running, not all" $
      withSystemTempDirectory "ws" $ \dir -> do
        let f = dir </> "workspaces.json"
        let stale   = (sampleWorkspace "bold-comet") { status = Running, containerId = "stale1" }
        let alive   = (sampleWorkspace "calm-river")  { status = Running, containerId = "live1" }
        let stopped = (sampleWorkspace "dark-nova")   { status = Stopped, containerId = "old1" }
        saveWorkspace f stale
        saveWorkspace f alive
        saveWorkspace f stopped
        healRunning f (Set.fromList ["live1"])
        r1 <- getByName f "bold-comet"
        r2 <- getByName f "calm-river"
        r3 <- getByName f "dark-nova"
        fmap (.status) r1 `shouldBe` Just Stopped
        fmap (.status) r2 `shouldBe` Just Running
        fmap (.status) r3 `shouldBe` Just Stopped

  describe "generateName" $ do
    it "produces adjective-noun format" $ do
      n <- generateName Set.empty
      let parts = T.splitOn "-" n
      length parts `shouldBe` 2

    it "avoids collisions by exhausting all but one combo" $ do
      -- Build the set of all possible names except one
      let allCombos = [ adj <> "-" <> noun
                      | adj  <- adjectives
                      , noun <- nouns
                      ]
      -- Leave exactly one name available: head adjective + head noun
      let target    = head adjectives <> "-" <> head nouns
      let takenSet  = Set.fromList (filter (/= target) allCombos)
      n <- generateName takenSet
      n `shouldBe` target

  describe "migration from sessions.json" $ do
    it "migrates sessions.json (drops id field) when workspaces.json absent" $
      withSystemTempDirectory "ws" $ \dir -> do
        let stateFile    = dir </> "workspaces.json"
        let sessionsFile = dir </> "sessions.json"
        -- Write a sessions.json that contains an "id" field
        writeFile sessionsFile $ unlines
          [ "[{"
          , "  \"id\": \"legacy-id-001\","
          , "  \"name\": \"bold-comet\","
          , "  \"dirs\": [\"/home/user/proj\"],"
          , "  \"container_id\": \"abc123\","
          , "  \"image\": \"ubuntu:24.04\","
          , "  \"created_at\": \"2024-01-01T00:00:00\","
          , "  \"last_used_at\": \"2024-01-01T00:00:00\","
          , "  \"status\": \"stopped\""
          , "}]"
          ]
        -- allWorkspaces on a non-existent workspaces.json triggers migration
        result <- allWorkspaces stateFile
        length result `shouldBe` 1
        (.name) (head result) `shouldBe` "bold-comet"

  describe "mounts field" $ do
    it "deserializes with empty mounts when field is absent" $
      withSystemTempDirectory "ws" $ \dir -> do
        let stateFile = dir </> "workspaces.json"
        writeFile stateFile $ unlines
          [ "[{"
          , "  \"name\": \"test-ws\","
          , "  \"dirs\": [\"/home/user/proj\"],"
          , "  \"container_id\": \"abc123\","
          , "  \"image\": \"ubuntu:24.04\","
          , "  \"created_at\": \"2024-01-01T00:00:00\","
          , "  \"last_used_at\": \"2024-01-01T00:00:00\","
          , "  \"status\": \"stopped\""
          , "}]"
          ]
        result <- allWorkspaces stateFile
        length result `shouldBe` 1
        (.mounts) (head result) `shouldBe` []

    it "round-trips workspaces with mounts" $
      withSystemTempDirectory "ws" $ \dir -> do
        let stateFile = dir </> "workspaces.json"
        let ws = (sampleWorkspace "mount-test")
              { mounts = [ Mount "/host/data" "/data" False
                         , Mount "/host/docs" "/docs" True
                         ]
              }
        saveWorkspace stateFile ws
        result <- allWorkspaces stateFile
        length result `shouldBe` 1
        let loaded = head result
        length loaded.mounts `shouldBe` 2
        (.source) (head loaded.mounts) `shouldBe` "/host/data"
        (.readOnly) (head loaded.mounts) `shouldBe` False
        (.source) (loaded.mounts !! 1) `shouldBe` "/host/docs"
        (.readOnly) (loaded.mounts !! 1) `shouldBe` True
