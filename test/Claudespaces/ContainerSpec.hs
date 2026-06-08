{-# LANGUAGE OverloadedStrings #-}

module Claudespaces.ContainerSpec (spec) where

import           Test.Hspec
import           System.FilePath        ((</>))
import           Data.List              (lookup)
import           Prelude                hiding (lookup)

import           Claudespaces.Config    (MountEntry (..))
import           Claudespaces.Container

spec :: Spec
spec = do
  describe "checkBasenameCollision" $ do
    it "raises on duplicate basenames" $
      checkBasenameCollision ["/group1/myapp", "/group2/myapp"]
        `shouldThrow` anyIOException

    it "allows distinct basenames" $
      -- Should not throw
      checkBasenameCollision ["/group1/app", "/group2/web"]

  describe "buildMounts" $ do
    let stateDir = "/state"
        homePath = "/home/user"
        hostPort = 7731
        noExtra  = []

    it "mounts user dir at /workspace/<basename>" $ do
      let mounts = buildMounts ["/home/user/myapp"] stateDir hostPort noExtra homePath
      let userMount = head mounts
      mTarget userMount `shouldBe` "/workspace/myapp"

    it "user dir mount is read-write" $ do
      let mounts = buildMounts ["/home/user/myapp"] stateDir hostPort noExtra homePath
      let userMount = head mounts
      mReadOnly userMount `shouldBe` False

    it "mounts state claude.json rw" $ do
      let mounts = buildMounts [] stateDir hostPort noExtra homePath
      let claudeJson = head mounts
      mSource claudeJson `shouldBe` "/state/claude.json"
      mTarget claudeJson `shouldBe` "/root/.claude.json"
      mReadOnly claudeJson `shouldBe` False

    it "mounts state projects rw" $ do
      let mounts = buildMounts [] stateDir hostPort noExtra homePath
      let projectsMount = mounts !! 1
      mSource projectsMount `shouldBe` "/state/projects"
      mTarget projectsMount `shouldBe` "/root/.claude/projects"
      mReadOnly projectsMount `shouldBe` False

    it "appends additional mounts" $ do
      let extra = [MountEntry "/host/docs" "/docs" True]
      let mounts = buildMounts [] stateDir hostPort extra homePath
      let lastMount = last mounts
      mSource lastMount `shouldBe` "/host/docs"
      mTarget lastMount `shouldBe` "/docs"
      mReadOnly lastMount `shouldBe` True

  describe "buildEnv" $ do
    let env = buildEnv 9999 "/home/user"

    it "includes IS_SANDBOX" $
      lookup "IS_SANDBOX" env `shouldBe` Just "1"

    it "includes HOST_HOME" $
      lookup "HOST_HOME" env `shouldBe` Just "/home/user"

    it "includes CLAUDESPACES_HOST_PORT" $
      lookup "CLAUDESPACES_HOST_PORT" env `shouldBe` Just "9999"
