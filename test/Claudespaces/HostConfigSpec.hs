{-# LANGUAGE OverloadedStrings #-}

module Claudespaces.HostConfigSpec (spec) where

import           Data.Aeson            (decode)
import qualified Data.ByteString.Lazy  as BL
import           Data.Map.Strict       (Map)
import qualified Data.Map.Strict       as Map
import           Data.Text             (Text)
import           System.FilePath       ((</>))
import           System.IO.Temp        (withSystemTempDirectory)
import           Test.Hspec

import           Claudespaces.HostConfig

writeFile' :: FilePath -> String -> IO ()
writeFile' = writeFile

spec :: Spec
spec = do
  describe "loadHostBridge" $ do
    it "returns default port when no config" $
      withSystemTempDirectory "hc" $ \dir -> do
        cfg <- loadHostBridge (dir </> "nonexistent.yaml")
        bridgePort cfg `shouldBe` 7731

    it "builtin notify always present" $
      withSystemTempDirectory "hc" $ \dir -> do
        cfg <- loadHostBridge (dir </> "nonexistent.yaml")
        Map.member "notify" (bridgeOperations cfg) `shouldBe` True

    it "user config wins on conflict" $
      withSystemTempDirectory "hc" $ \dir -> do
        let cfgFile = dir </> "config.yaml"
        writeFile' cfgFile $ unlines
          [ "host_bridge:"
          , "  operations:"
          , "    notify:"
          , "      command: 'custom-notify {msg}'"
          , "      args: [msg]"
          , "      async: true"
          , "      override: notify-send"
          ]
        cfg <- loadHostBridge cfgFile
        let ops = bridgeOperations cfg
        case Map.lookup "notify" ops of
          Nothing -> expectationFailure "notify operation not found"
          Just op -> opCommand op `shouldBe` "custom-notify {msg}"

    it "loads custom port" $
      withSystemTempDirectory "hc" $ \dir -> do
        let cfgFile = dir </> "config.yaml"
        writeFile' cfgFile $ unlines
          [ "host_bridge:"
          , "  port: 9999"
          ]
        cfg <- loadHostBridge cfgFile
        bridgePort cfg `shouldBe` 9999

  describe "overridesManifest" $ do
    it "extracts override operations" $ do
      let ops = Map.fromList
            [ ("notify", Operation "notify-send {summary} {body}" ["summary", "body"] True (Just "notify-send"))
            ]
      overridesManifest ops `shouldBe` Map.fromList [("notify-send", "notify")]

    it "returns empty map when no overrides" $ do
      let ops = Map.fromList
            [ ("myop", Operation "do-something" [] False Nothing)
            ]
      overridesManifest ops `shouldBe` Map.empty

  describe "writeShims" $ do
    it "creates manifest file" $
      withSystemTempDirectory "shims" $ \dir -> do
        let shimsPath = dir </> "shims.json"
        let ops = Map.fromList
              [ ("notify", Operation "notify-send {summary} {body}" ["summary", "body"] True (Just "notify-send"))
              ]
        writeShims shimsPath ops
        contents <- BL.readFile shimsPath
        let decoded = decode contents :: Maybe (Map Text Text)
        decoded `shouldBe` Just (Map.fromList [("notify-send", "notify")])
