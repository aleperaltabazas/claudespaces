
module Claudespaces.HostServerSpec (spec) where

import Claudespaces.HostConfig (Operation (..))
import Claudespaces.HostServer (buildCommand, buildPassthroughCommand)
import Data.Aeson (Value (..))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Map.Strict as Map
import qualified Data.Vector as V
import Test.Hspec

spec :: Spec
spec = do
  describe "buildCommand" $ do
    it "substitutes named placeholders" $ do
      let op = Operation "notify-send {summary} {body}" ["summary", "body"] True Nothing False
          args = Map.fromList [("summary", "hi"), ("body", "world")]
      buildCommand op args `shouldBe` Right ["notify-send", "hi", "world"]

    it "returns Left on missing placeholder" $ do
      let op = Operation "notify-send {summary} {body}" ["summary", "body"] True Nothing False
          args = Map.fromList [("summary", "hi")]
      buildCommand op args `shouldBe` Left "missing argument: body"

  describe "buildPassthroughCommand" $ do
    it "appends all positional args" $ do
      let op = Operation "gh" [] False (Just "gh") True
          args = Array (V.fromList [String "pr", String "list", String "--repo", String "foo/bar"])
      buildPassthroughCommand op args `shouldBe` Right ["gh", "pr", "list", "--repo", "foo/bar"]

    it "works with no args" $ do
      let op = Operation "gh" [] False (Just "gh") True
      buildPassthroughCommand op (Array V.empty) `shouldBe` Right ["gh"]

    it "works with multi-word base command" $ do
      let op = Operation "git log" [] False Nothing True
          args = Array (V.fromList [String "--oneline"])
      buildPassthroughCommand op args `shouldBe` Right ["git", "log", "--oneline"]

    it "ignores non-array args" $ do
      let op = Operation "gh" [] False Nothing True
          args = Object (KM.fromList [(Key.fromText "foo", String "bar")])
      buildPassthroughCommand op args `shouldBe` Right ["gh"]
