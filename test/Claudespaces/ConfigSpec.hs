{-# LANGUAGE OverloadedStrings #-}

module Claudespaces.ConfigSpec (spec) where

import Test.Hspec
import System.IO.Temp (withSystemTempDirectory)
import System.FilePath ((</>))
import Claudespaces.Config

writeFile' :: FilePath -> String -> IO ()
writeFile' = writeFile

spec :: Spec
spec = do
  describe "parseMount" $ do
    it "parses src:dst as rw" $
      parseMount "/host/path:/container/path"
        `shouldBe` Right (MountEntry "/host/path" "/container/path" False)

    it "parses src:dst:rw" $
      parseMount "/host/path:/container/path:rw"
        `shouldBe` Right (MountEntry "/host/path" "/container/path" False)

    it "parses src:dst:ro" $
      parseMount "/host/path:/container/path:ro"
        `shouldBe` Right (MountEntry "/host/path" "/container/path" True)

    it "rejects single-part entry" $
      parseMount "/only-one-part" `shouldSatisfy` isLeft

    it "rejects invalid mode" $
      parseMount "/host/path:/container/path:rw2" `shouldSatisfy` isLeft

  describe "loadConfig" $ do
    it "returns empty config when no files exist" $
      withSystemTempDirectory "cfg" $ \dir -> do
        cfg <- loadConfig dir (dir </> "nonexistent-global.yaml")
        cfg `shouldBe` emptyConfig

    it "parses image key from local config" $
      withSystemTempDirectory "cfg" $ \dir -> do
        writeFile' (dir </> "claudespaces.yml") "image: ubuntu:24.04\n"
        cfg <- loadConfig dir (dir </> "nope.yaml")
        cfgImage cfg `shouldBe` Just "ubuntu:24.04"

    it "parses dockerfile key from local config" $
      withSystemTempDirectory "cfg" $ \dir -> do
        writeFile' (dir </> "claudespaces.yml") "dockerfile: ./Dockerfile\n"
        cfg <- loadConfig dir (dir </> "nope.yaml")
        cfgDockerfile cfg `shouldBe` Just "./Dockerfile"

    it "raises on both image and dockerfile in local" $
      withSystemTempDirectory "cfg" $ \dir -> do
        writeFile' (dir </> "claudespaces.yml") "image: foo\ndockerfile: ./Dockerfile\n"
        loadConfig dir (dir </> "nope.yaml") `shouldThrow` anyIOException

    it "parses directories from local config" $
      withSystemTempDirectory "cfg" $ \dir -> do
        writeFile' (dir </> "claudespaces.yml") "directories:\n  - ~/proj1\n  - ~/proj2\n"
        cfg <- loadConfig dir (dir </> "nope.yaml")
        cfgDirectories cfg `shouldBe` ["~/proj1", "~/proj2"]

    it "returns empty config for empty yaml file" $
      withSystemTempDirectory "cfg" $ \dir -> do
        writeFile' (dir </> "claudespaces.yml") ""
        cfg <- loadConfig dir (dir </> "nope.yaml")
        cfg `shouldBe` emptyConfig

    it "exposes global dockerfile as globalDockerfile" $
      withSystemTempDirectory "cfg" $ \dir -> do
        writeFile' (dir </> "global.yaml") "dockerfile: ~/.config/claudespaces/Dockerfile\n"
        cfg <- loadConfig dir (dir </> "global.yaml")
        cfgGlobalDockerfile cfg `shouldBe` Just "~/.config/claudespaces/Dockerfile"
        cfgDockerfile cfg `shouldBe` Nothing

    it "raises on both image and dockerfile in global" $
      withSystemTempDirectory "cfg" $ \dir -> do
        writeFile' (dir </> "global.yaml") "image: foo\ndockerfile: ./Dockerfile\n"
        loadConfig dir (dir </> "global.yaml") `shouldThrow` anyIOException

    it "local image overrides global image" $
      withSystemTempDirectory "cfg" $ \dir -> do
        writeFile' (dir </> "global.yaml") "image: ubuntu:24.04\n"
        writeFile' (dir </> "claudespaces.yml") "image: debian:12\n"
        cfg <- loadConfig dir (dir </> "global.yaml")
        cfgImage cfg `shouldBe` Just "debian:12"

    it "uses global image when no local image" $
      withSystemTempDirectory "cfg" $ \dir -> do
        writeFile' (dir </> "global.yaml") "image: debian:12\n"
        cfg <- loadConfig dir (dir </> "global.yaml")
        cfgImage cfg `shouldBe` Just "debian:12"

    it "keeps both global dockerfile and local dockerfile" $
      withSystemTempDirectory "cfg" $ \dir -> do
        writeFile' (dir </> "global.yaml") "dockerfile: ~/.config/claudespaces/Dockerfile\n"
        writeFile' (dir </> "claudespaces.yml") "dockerfile: ./Dockerfile\n"
        cfg <- loadConfig dir (dir </> "global.yaml")
        cfgGlobalDockerfile cfg `shouldBe` Just "~/.config/claudespaces/Dockerfile"
        cfgDockerfile cfg `shouldBe` Just "./Dockerfile"

    it "keeps global dockerfile and local image" $
      withSystemTempDirectory "cfg" $ \dir -> do
        writeFile' (dir </> "global.yaml") "dockerfile: ~/.config/claudespaces/Dockerfile\n"
        writeFile' (dir </> "claudespaces.yml") "image: debian:12\n"
        cfg <- loadConfig dir (dir </> "global.yaml")
        cfgGlobalDockerfile cfg `shouldBe` Just "~/.config/claudespaces/Dockerfile"
        cfgImage cfg `shouldBe` Just "debian:12"

    it "merges directories from global and local" $
      withSystemTempDirectory "cfg" $ \dir -> do
        writeFile' (dir </> "global.yaml") "directories:\n  - ~/global-proj\n"
        writeFile' (dir </> "claudespaces.yml") "directories:\n  - ~/local-proj\n"
        cfg <- loadConfig dir (dir </> "global.yaml")
        cfgDirectories cfg `shouldBe` ["~/global-proj", "~/local-proj"]

  describe "additional mounts" $ do
    it "parses local additional-mounts" $
      withSystemTempDirectory "cfg" $ \dir -> do
        writeFile' (dir </> "claudespaces.yml") "additional-mounts:\n  - /src:/dst:ro\n"
        cfg <- loadConfig dir (dir </> "nope.yaml")
        cfgAdditionalMounts cfg `shouldBe` [MountEntry "/src" "/dst" True]

    it "parses global additional-mounts" $
      withSystemTempDirectory "cfg" $ \dir -> do
        writeFile' (dir </> "global.yaml") "additional-mounts:\n  - /g:/cg:rw\n"
        cfg <- loadConfig dir (dir </> "global.yaml")
        cfgAdditionalMounts cfg `shouldBe` [MountEntry "/g" "/cg" False]

    it "merges global and local additional-mounts" $
      withSystemTempDirectory "cfg" $ \dir -> do
        writeFile' (dir </> "global.yaml") "additional-mounts:\n  - /g:/cg\n"
        writeFile' (dir </> "claudespaces.yml") "additional-mounts:\n  - /l:/cl:ro\n"
        cfg <- loadConfig dir (dir </> "global.yaml")
        cfgAdditionalMounts cfg `shouldBe`
          [ MountEntry "/g" "/cg" False
          , MountEntry "/l" "/cl" True
          ]

    it "raises on overlapping container targets" $
      withSystemTempDirectory "cfg" $ \dir -> do
        writeFile' (dir </> "global.yaml") "additional-mounts:\n  - /g:/shared\n"
        writeFile' (dir </> "claudespaces.yml") "additional-mounts:\n  - /l:/shared\n"
        loadConfig dir (dir </> "global.yaml") `shouldThrow` anyIOException

    it "omits additional_mounts when none defined" $
      withSystemTempDirectory "cfg" $ \dir -> do
        cfg <- loadConfig dir (dir </> "nope.yaml")
        cfgAdditionalMounts cfg `shouldBe` []

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft _ = False
