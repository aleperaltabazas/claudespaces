
module Claudespaces.WorkspacesSpec (spec) where

import           Test.Hspec
import           System.IO.Temp      (withSystemTempDirectory)
import           System.FilePath     ((</>))
import           Data.Text           (Text)
import qualified Data.Text           as T
import qualified Data.Set            as Set
import           Data.List           (sort)

import           Claudespaces.Workspaces

-- | A minimal workspace for use in tests
sampleWorkspace :: Text -> Workspace
sampleWorkspace name = Workspace
  { wsName        = name
  , wsDirs        = ["/home/user/proj"]
  , wsContainerId = "abc123"
  , wsImage       = "ubuntu:24.04"
  , wsCreatedAt   = "2024-01-01T00:00:00"
  , wsLastUsedAt  = "2024-01-01T00:00:00"
  , wsStatus      = "stopped"
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
        let ws1 = (sampleWorkspace "bold-comet") { wsDirs = ["/home/user/proj"] }
        let ws2 = (sampleWorkspace "calm-river")  { wsDirs = ["/home/user/proj"] }
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
        updateWorkspace f "bold-comet" (\ws -> ws { wsStatus = "running" })
        result <- getByName f "bold-comet"
        fmap wsStatus result `shouldBe` Just "running"

    it "leaves other fields intact" $
      withSystemTempDirectory "ws" $ \dir -> do
        let f = dir </> "workspaces.json"
        let ws = sampleWorkspace "bold-comet"
        saveWorkspace f ws
        updateWorkspace f "bold-comet" (\w -> w { wsStatus = "running" })
        result <- getByName f "bold-comet"
        fmap wsImage result `shouldBe` Just "ubuntu:24.04"
        fmap wsDirs  result `shouldBe` Just ["/home/user/proj"]

    it "raises when name not found" $
      withSystemTempDirectory "ws" $ \dir -> do
        let f = dir </> "workspaces.json"
        updateWorkspace f "no-such-name" id `shouldThrow` anyIOException

  describe "removeWorkspace" $ do
    it "removes the correct record" $
      withSystemTempDirectory "ws" $ \dir -> do
        let f = dir </> "workspaces.json"
        saveWorkspace f (sampleWorkspace "bold-comet")
        saveWorkspace f (sampleWorkspace "calm-river")
        removeWorkspace f "bold-comet"
        result <- allWorkspaces f
        map wsName result `shouldBe` ["calm-river"]

  describe "healRunning" $ do
    it "marks stale running workspaces as stopped" $
      withSystemTempDirectory "ws" $ \dir -> do
        let f = dir </> "workspaces.json"
        let ws = (sampleWorkspace "bold-comet") { wsStatus = "running", wsContainerId = "stale123" }
        saveWorkspace f ws
        healRunning f (Set.fromList [])
        result <- getByName f "bold-comet"
        fmap wsStatus result `shouldBe` Just "stopped"

    it "leaves actually running workspaces unchanged" $
      withSystemTempDirectory "ws" $ \dir -> do
        let f = dir </> "workspaces.json"
        let ws = (sampleWorkspace "bold-comet") { wsStatus = "running", wsContainerId = "live123" }
        saveWorkspace f ws
        healRunning f (Set.fromList ["live123"])
        result <- getByName f "bold-comet"
        fmap wsStatus result `shouldBe` Just "running"

    it "leaves stopped workspaces unchanged" $
      withSystemTempDirectory "ws" $ \dir -> do
        let f = dir </> "workspaces.json"
        let ws = (sampleWorkspace "bold-comet") { wsStatus = "stopped", wsContainerId = "abc123" }
        saveWorkspace f ws
        healRunning f (Set.fromList [])
        result <- getByName f "bold-comet"
        fmap wsStatus result `shouldBe` Just "stopped"

    it "only changes stale running, not all" $
      withSystemTempDirectory "ws" $ \dir -> do
        let f = dir </> "workspaces.json"
        let stale   = (sampleWorkspace "bold-comet") { wsStatus = "running", wsContainerId = "stale1" }
        let alive   = (sampleWorkspace "calm-river")  { wsStatus = "running", wsContainerId = "live1" }
        let stopped = (sampleWorkspace "dark-nova")   { wsStatus = "stopped", wsContainerId = "old1" }
        saveWorkspace f stale
        saveWorkspace f alive
        saveWorkspace f stopped
        healRunning f (Set.fromList ["live1"])
        r1 <- getByName f "bold-comet"
        r2 <- getByName f "calm-river"
        r3 <- getByName f "dark-nova"
        fmap wsStatus r1 `shouldBe` Just "stopped"
        fmap wsStatus r2 `shouldBe` Just "running"
        fmap wsStatus r3 `shouldBe` Just "stopped"

  describe "generateName" $ do
    it "produces adjective-noun format" $ do
      name <- generateName Set.empty
      let parts = T.splitOn "-" name
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
      name <- generateName takenSet
      name `shouldBe` target

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
        wsName (head result) `shouldBe` "bold-comet"
