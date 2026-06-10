
module Claudespaces.HostConfigSpec (spec) where

import Claudespaces.HostConfig
import Data.Aeson (decode)
import qualified Data.ByteString.Lazy as BL
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

writeFile' :: FilePath -> String -> IO ()
writeFile' = writeFile

spec :: Spec
spec = do
  describe "loadHostBridge" $ do
    it "returns default port when no config" $
      withSystemTempDirectory "hc" $ \dir -> do
        cfg <- loadHostBridge (dir </> "nonexistent.yaml")
        cfg.port `shouldBe` 7731

    it "builtin notify always present" $
      withSystemTempDirectory "hc" $ \dir -> do
        cfg <- loadHostBridge (dir </> "nonexistent.yaml")
        Map.member "notify" cfg.operations `shouldBe` True

    it "user config wins on conflict" $
      withSystemTempDirectory "hc" $ \dir -> do
        let cfgFile = dir </> "config.yaml"
        writeFile' cfgFile $
          unlines
            [ "host_bridge:",
              "  operations:",
              "    notify:",
              "      command: 'custom-notify {msg}'",
              "      args: [msg]",
              "      async: true",
              "      override: notify-send"
            ]
        cfg <- loadHostBridge cfgFile
        let ops = cfg.operations
        case Map.lookup "notify" ops of
          Nothing -> expectationFailure "notify operation not found"
          Just op -> op.command `shouldBe` "custom-notify {msg}"

    it "loads custom port" $
      withSystemTempDirectory "hc" $ \dir -> do
        let cfgFile = dir </> "config.yaml"
        writeFile' cfgFile $
          unlines
            [ "host_bridge:",
              "  port: 9999"
            ]
        cfg <- loadHostBridge cfgFile
        cfg.port `shouldBe` 9999

    it "loads passthrough operations" $
      withSystemTempDirectory "hc" $ \dir -> do
        let cfgFile = dir </> "config.yaml"
        writeFile' cfgFile $
          unlines
            [ "host_bridge:",
              "  operations:",
              "    gh:",
              "      command: gh",
              "      passthrough: true",
              "      override: gh"
            ]
        cfg <- loadHostBridge cfgFile
        case Map.lookup "gh" cfg.operations of
          Nothing -> expectationFailure "gh operation not found"
          Just op -> do
            op.passthrough `shouldBe` True
            op.override `shouldBe` Just "gh"

    it "passthrough defaults to false" $
      withSystemTempDirectory "hc" $ \dir -> do
        let cfgFile = dir </> "config.yaml"
        writeFile' cfgFile $
          unlines
            [ "host_bridge:",
              "  operations:",
              "    myop:",
              "      command: do-something"
            ]
        cfg <- loadHostBridge cfgFile
        case Map.lookup "myop" cfg.operations of
          Nothing -> expectationFailure "myop not found"
          Just op -> op.passthrough `shouldBe` False

  describe "overridesManifest" $ do
    it "extracts override operations" $ do
      let ops =
            Map.fromList
              [ ("notify", Operation "notify-send {summary} {body}" ["summary", "body"] True (Just "notify-send") False)
              ]
      overridesManifest ops `shouldBe` Map.fromList [("notify-send", "notify")]

    it "returns empty map when no overrides" $ do
      let ops =
            Map.fromList
              [ ("myop", Operation "do-something" [] False Nothing False)
              ]
      overridesManifest ops `shouldBe` Map.empty

  describe "writeShims" $ do
    it "creates manifest file" $
      withSystemTempDirectory "shims" $ \dir -> do
        let shimsPath = dir </> "shims.json"
        let ops =
              Map.fromList
                [ ("notify", Operation "notify-send {summary} {body}" ["summary", "body"] True (Just "notify-send") False)
                ]
        writeShims shimsPath ops
        contents <- BL.readFile shimsPath
        let decoded = decode contents :: Maybe (Map Text Text)
        decoded `shouldBe` Just (Map.fromList [("notify-send", "notify")])
