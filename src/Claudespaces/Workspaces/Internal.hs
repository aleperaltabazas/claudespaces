module Claudespaces.Workspaces.Internal
  ( adjectives
  , nouns
  ) where

import Data.Text (Text)

adjectives :: [Text]
adjectives =
  [ "bold", "calm", "dark", "deep", "fast", "free", "hard", "high"
  , "kind", "last", "late", "long", "loud", "mild", "near", "next"
  , "nice", "open", "pure", "rare", "real", "rich", "safe", "slim"
  , "slow", "soft", "tall", "thin", "tiny", "vast", "warm", "wide"
  , "wild", "wise", "blue", "cold", "cool", "dull", "fair", "firm"
  , "flat", "full", "gray", "keen", "lazy", "lean", "live", "lost"
  , "mad",  "neat"
  ]

nouns :: [Text]
nouns =
  [ "space", "orbit", "comet", "cloud", "creek", "delta", "drift"
  , "dusk",  "echo",  "field", "flame", "flare", "flash", "flow"
  , "forge", "frost", "glade", "gleam", "grove", "haven", "haze"
  , "isle",  "lake",  "leap",  "light", "lodge", "loom",  "lunar"
  , "marsh", "mist",  "moon",  "moss",  "nova",  "ocean", "peak"
  , "plain", "prism", "pulse", "ridge", "rift",  "river", "rock"
  , "shade", "shore", "sky",   "slope", "snow",  "solar", "spark"
  , "star",  "stone"
  ]
