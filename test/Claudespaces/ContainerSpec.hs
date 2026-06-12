
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
  describe "containerHome" $ do
    it "returns /root when uid is 0" $
      containerHome 0 `shouldBe` "/root"

    it "returns /home/claude when uid is non-zero" $
      containerHome 1000 `shouldBe` "/home/claude"

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
        cHome = "/home/claude"

    it "mounts user dir at /workspace/<basename>" $ do
      let mounts = buildMounts ["/home/user/myapp"] stateDir hostPort noExtra homePath cHome
      let userMount = head mounts
      userMount.target `shouldBe` "/workspace/myapp"

    it "user dir mount is read-write" $ do
      let mounts = buildMounts ["/home/user/myapp"] stateDir hostPort noExtra homePath cHome
      let userMount = head mounts
      userMount.readOnly `shouldBe` False

    it "mounts state claude.json at container home" $ do
      let mounts = buildMounts [] stateDir hostPort noExtra homePath cHome
      let claudeJson = head mounts
      claudeJson.source `shouldBe` "/state/claude.json"
      claudeJson.target `shouldBe` "/home/claude/.claude.json"
      claudeJson.readOnly `shouldBe` False

    it "mounts state projects at container home" $ do
      let mounts = buildMounts [] stateDir hostPort noExtra homePath cHome
      let projectsMount = mounts !! 1
      projectsMount.source `shouldBe` "/state/projects"
      projectsMount.target `shouldBe` "/home/claude/.claude/projects"
      projectsMount.readOnly `shouldBe` False

    it "uses /root for state mounts when container home is /root" $ do
      let mounts = buildMounts [] stateDir hostPort noExtra homePath "/root"
      let claudeJson = head mounts
      claudeJson.target `shouldBe` "/root/.claude.json"

    it "mounts shims.json read-only" $ do
      let mounts = buildMounts [] stateDir hostPort noExtra homePath cHome
      let shimsMount = mounts !! 2
      shimsMount.source `shouldBe` "/home/user/.claudespaces/shims.json"
      shimsMount.target `shouldBe` "/claudespaces/shims.json"
      shimsMount.readOnly `shouldBe` True

    it "appends additional mounts" $ do
      let extra = [Mount "/host/docs" "/docs" True]
      let mounts = buildMounts [] stateDir hostPort extra homePath cHome
      let lastMount = last mounts
      lastMount.source `shouldBe` "/host/docs"
      lastMount.target `shouldBe` "/docs"
      lastMount.readOnly `shouldBe` True

  describe "buildEnv" $ do
    let env = buildEnv 9999 "/home/user" 1000 1000

    it "includes IS_SANDBOX" $
      lookup "IS_SANDBOX" env `shouldBe` Just "1"

    it "includes HOST_HOME" $
      lookup "HOST_HOME" env `shouldBe` Just "/home/user"

    it "includes CLAUDESPACES_HOST_PORT" $
      lookup "CLAUDESPACES_HOST_PORT" env `shouldBe` Just "9999"

    it "includes HOST_UID" $
      lookup "HOST_UID" env `shouldBe` Just "1000"

    it "includes HOST_GID" $
      lookup "HOST_GID" env `shouldBe` Just "1000"
