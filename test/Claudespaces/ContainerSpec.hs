
module Claudespaces.ContainerSpec (spec) where

import Claudespaces.Config (Mount (..))
import Claudespaces.Container
import Data.Either (isLeft)
import Data.List (lookup)
import System.FilePath ((</>))
import Test.Hspec
import Prelude hiding (lookup)

spec :: Spec
spec = do
  describe "checkBasenameCollision" $ do
    it "returns Left on duplicate basenames" $
      checkBasenameCollision ["/group1/myapp", "/group2/myapp"]
        `shouldSatisfy` isLeft

    it "returns Right () for distinct basenames" $
      checkBasenameCollision ["/group1/app", "/group2/web"]
        `shouldBe` Right ()

  describe "buildMounts" $ do
    let stateDir = "/state"
        homePath = "/home/user"
        hostPort = 7731
        noExtra = []

    it "mounts user dir at /workspace/<basename>" $ do
      let mounts = buildMounts ["/home/user/myapp"] stateDir hostPort noExtra homePath
      let userMount = head mounts
      userMount.target `shouldBe` "/workspace/myapp"

    it "user dir mount is read-write" $ do
      let mounts = buildMounts ["/home/user/myapp"] stateDir hostPort noExtra homePath
      let userMount = head mounts
      userMount.readOnly `shouldBe` False

    it "mounts state claude.json rw" $ do
      let mounts = buildMounts [] stateDir hostPort noExtra homePath
      let claudeJson = head mounts
      claudeJson.source `shouldBe` "/state/claude.json"
      claudeJson.target `shouldBe` "/root/.claude.json"
      claudeJson.readOnly `shouldBe` False

    it "mounts state projects rw" $ do
      let mounts = buildMounts [] stateDir hostPort noExtra homePath
      let projectsMount = mounts !! 1
      projectsMount.source `shouldBe` "/state/projects"
      projectsMount.target `shouldBe` "/root/.claude/projects"
      projectsMount.readOnly `shouldBe` False

    it "mounts shims.json read-only" $ do
      let mounts = buildMounts [] stateDir hostPort noExtra homePath
      let shimsMount = mounts !! 2
      shimsMount.source `shouldBe` "/home/user/.claudespaces/shims.json"
      shimsMount.target `shouldBe` "/claudespaces/shims.json"
      shimsMount.readOnly `shouldBe` True

    it "appends additional mounts" $ do
      let extra = [Mount "/host/docs" "/docs" True]
      let mounts = buildMounts [] stateDir hostPort extra homePath
      let lastMount = last mounts
      lastMount.source `shouldBe` "/host/docs"
      lastMount.target `shouldBe` "/docs"
      lastMount.readOnly `shouldBe` True

  describe "buildEnv" $ do
    let env = buildEnv 9999 "/home/user"

    it "includes IS_SANDBOX" $
      lookup "IS_SANDBOX" env `shouldBe` Just "1"

    it "includes HOST_HOME" $
      lookup "HOST_HOME" env `shouldBe` Just "/home/user"

    it "includes CLAUDESPACES_HOST_PORT" $
      lookup "CLAUDESPACES_HOST_PORT" env `shouldBe` Just "9999"
