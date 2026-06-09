module Main where

import Claudespaces.Env        (mkEnv, Env (..))
import Claudespaces.HostConfig (BridgeConfig (..), loadHostBridge)
import Claudespaces.HostServer (runServer)

main :: IO ()
main = do
  env <- mkEnv
  cfg <- loadHostBridge env.globalConfigPath
  runServer cfg.port cfg.operations
