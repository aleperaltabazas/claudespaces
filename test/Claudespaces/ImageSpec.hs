
module Claudespaces.ImageSpec (spec) where

import           Test.Hspec
import           Data.Text           (Text)
import qualified Data.Text           as T

import           Claudespaces.Image

spec :: Spec
spec = do
  describe "sanitizeTag" $ do
    it "replaces colons and slashes with dashes" $
      sanitizeTag "registry.io/org/image:v1.2" `shouldBe` "registry.io-org-image-v1.2"

    it "leaves plain tags unchanged" $
      sanitizeTag "ubuntu" `shouldBe` "ubuntu"

    it "replaces only colons and slashes" $
      sanitizeTag "ubuntu:24.04" `shouldBe` "ubuntu-24.04"

  describe "intermediateTag" $ do
    it "starts with claudespaces-base:" $
      T.isPrefixOf "claudespaces-base:" (intermediateTag "ubuntu:24.04" "abc123" 1000)
        `shouldBe` True

    it "contains sanitized base tag" $
      T.isInfixOf "ubuntu-24.04" (intermediateTag "ubuntu:24.04" "abc123" 1000)
        `shouldBe` True

    it "contains hash" $
      T.isInfixOf "abc123" (intermediateTag "ubuntu:24.04" "abc123" 1000)
        `shouldBe` True

    it "produces expected format" $
      intermediateTag "ubuntu:24.04" "abc123" 1000
        `shouldBe` "claudespaces-base:ubuntu-24.04-abc123-uid1000"

    it "differs for different UIDs" $
      intermediateTag "ubuntu:24.04" "abc123" 1000
        `shouldNotBe` intermediateTag "ubuntu:24.04" "abc123" 1001

  describe "globalTag" $ do
    it "starts with claudespaces-global:" $
      T.isPrefixOf "claudespaces-global:" (globalTag "/some/dockerfile" "ubuntu:24.04")
        `shouldBe` True

    it "produces consistent results" $
      globalTag "/some/dockerfile" "ubuntu:24.04"
        `shouldBe` globalTag "/some/dockerfile" "ubuntu:24.04"

    it "differs for different inputs" $
      globalTag "/some/dockerfile" "ubuntu:24.04"
        `shouldNotBe` globalTag "/other/dockerfile" "ubuntu:24.04"

  describe "customTag" $ do
    it "starts with claudespaces-custom:" $
      T.isPrefixOf "claudespaces-custom:" (customTag "/some/dockerfile" "ubuntu:24.04")
        `shouldBe` True

    it "produces consistent results" $
      customTag "/some/dockerfile" "ubuntu:24.04"
        `shouldBe` customTag "/some/dockerfile" "ubuntu:24.04"

    it "differs from globalTag for same inputs" $
      customTag "/some/dockerfile" "ubuntu:24.04"
        `shouldNotBe` globalTag "/some/dockerfile" "ubuntu:24.04"
