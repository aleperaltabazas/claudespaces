module Claudespaces.HostServer
  ( runServer
  , handleRun
  , isRunning
  , startServer
  , stopServerIfLast
  , buildCommand
  , buildPassthroughCommand
  , pidFilePath
  , logFilePath
  ) where

import           Control.Exception         (SomeException, catch, try)
import           Control.Monad             (when)
import           Control.Monad.IO.Class    (liftIO)
import           Data.Aeson                (FromJSON (..), Value (..), object,
                                            withObject, (.:), (.:?), (.=))
import qualified Data.Aeson                as Aeson
import qualified Data.Aeson.Key            as Key
import qualified Data.Aeson.KeyMap         as KM
import           Data.Map.Strict           (Map)
import qualified Data.Map.Strict           as Map
import           Data.Text                 (Text)
import qualified Data.Text                 as T
import qualified Data.Vector               as V
import           Network.HTTP.Types.Status (mkStatus)
import           Network.Socket            (Family (..), SockAddr (..),
                                            SocketType (..), close, connect,
                                            defaultProtocol, socket,
                                            tupleToHostAddress)
import           System.Directory          (createDirectoryIfMissing,
                                            getHomeDirectory, removeFile)
import           System.Exit               (ExitCode (..))
import           System.FilePath           (takeDirectory, (</>))
import           System.IO.Error           (isDoesNotExistError)
import           System.Posix.Signals      (sigTERM, signalProcess)
import           System.Posix.Types        (CPid (..))
import           System.IO                 (IOMode (..), openFile)
import           System.Process            (CreateProcess (..), ProcessHandle,
                                            StdStream (..), createProcess,
                                            proc, readProcessWithExitCode,
                                            spawnProcess)
import           System.Process.Internals  (ProcessHandle__ (..),
                                            withProcessHandle)
import           Web.Scotty                (ActionM, ScottyM, json, jsonData,
                                            literal, post, scotty)
import qualified Web.Scotty                as Scotty

import           Claudespaces.HostConfig   (Operation (..))
import           Claudespaces.Workspaces   (Workspace (..), Status (..), allWorkspaces,
                                            defaultStateFile)

-- ---------------------------------------------------------------------------
-- File paths
-- ---------------------------------------------------------------------------

pidFilePath :: IO FilePath
pidFilePath = do
  home <- getHomeDirectory
  pure $ home </> ".claudespaces" </> "host_bridge.pid"

logFilePath :: IO FilePath
logFilePath = do
  home <- getHomeDirectory
  pure $ home </> ".claudespaces" </> "host_bridge.log"

-- ---------------------------------------------------------------------------
-- buildCommand
-- ---------------------------------------------------------------------------

-- Helper: strip a suffix from Text
stripSuffix :: Text -> Text -> Maybe Text
stripSuffix suffix t
  | T.isSuffixOf suffix t = Just (T.dropEnd (T.length suffix) t)
  | otherwise             = Nothing

-- | Substitute {key} placeholders in a command string.
-- Returns the command split into [prog, arg1, arg2, ...], or Left if a
-- placeholder has no matching value.
buildCommand :: Operation -> Map Text Text -> Either Text [String]
buildCommand op namedArgs =
  let parts = T.words op.command
  in  mapM substituteOne parts
  where
    substituteOne part =
      case (T.stripPrefix "{" part >>= stripSuffix "}") of
        Just key ->
          case Map.lookup key namedArgs of
            Just val -> Right (T.unpack val)
            Nothing  -> Left ("missing argument: " <> key)
        Nothing -> Right (T.unpack part)

-- ---------------------------------------------------------------------------
-- buildPassthroughCommand
-- ---------------------------------------------------------------------------

-- | Build a command by appending all positional args verbatim to the base
-- command words. Used for operations that proxy an entire CLI (e.g. gh).
buildPassthroughCommand :: Operation -> Value -> Either Text [String]
buildPassthroughCommand op argsVal =
  let base = map T.unpack (T.words op.command)
      extra = case argsVal of
                Array vec -> map (T.unpack . valueToText) (V.toList vec)
                _         -> []
  in  if null base
        then Left "empty command"
        else Right (base ++ extra)

-- ---------------------------------------------------------------------------
-- handleRun
-- ---------------------------------------------------------------------------

data RunRequest = RunRequest
  { op   :: Text
  , args :: Maybe Value
  } deriving (Show)

instance FromJSON RunRequest where
  parseJSON = withObject "RunRequest" $ \o -> do
    op'   <- o .:  "op"
    args' <- o .:? "args"
    pure $ RunRequest op' args'

-- | Execute an operation by name, resolving args, and return (httpStatus, body).
handleRun :: Text -> Value -> Map Text Operation -> IO (Int, Value)
handleRun opName argsVal ops =
  case Map.lookup opName ops of
    Nothing ->
      pure (400, object ["error" .= ("unknown operation: " <> opName)])
    Just op -> do
      let cmdResult = if op.passthrough
                        then buildPassthroughCommand op argsVal
                        else buildCommand op (resolveArgs op argsVal)
      case cmdResult of
        Left err ->
          pure (400, object ["error" .= err])
        Right [] ->
          pure (400, object ["error" .= ("empty command" :: Text)])
        Right (prog:args) ->
          if op.async
            then do
              result <- try (spawnProcess prog args) :: IO (Either SomeException ProcessHandle)
              case result of
                Left err -> pure (500, object ["error" .= show err])
                Right _  -> pure (200, object ["status" .= ("ok" :: Text)])
            else do
              result <- try (readProcessWithExitCode prog args "") :: IO (Either SomeException (ExitCode, String, String))
              case result of
                Left err -> pure (500, object ["error" .= show err])
                Right (code, out, err) ->
                  let exitCodeInt = case code of
                                      ExitSuccess   -> 0 :: Int
                                      ExitFailure n -> n
                  in pure (200, object
                       [ "stdout"    .= out
                       , "stderr"    .= err
                       , "exit_code" .= exitCodeInt
                       ])

-- | Convert incoming JSON args to a named map.
-- Array values are zipped positionally with the op's declared arg names.
-- Object values extract text values by key.
resolveArgs :: Operation -> Value -> Map Text Text
resolveArgs op (Array vec) =
  Map.fromList $ zip op.args (map valueToText (V.toList vec))
resolveArgs _ (Object km) =
  Map.fromList
    [ (Key.toText k, valueToText v)
    | (k, v) <- KM.toList km
    ]
resolveArgs _ _ = Map.empty

valueToText :: Value -> Text
valueToText (String t) = t
valueToText (Number n) = T.pack (show n)
valueToText (Bool b)   = if b then "true" else "false"
valueToText Null       = ""
valueToText v          = T.pack (show v)

-- ---------------------------------------------------------------------------
-- runServer
-- ---------------------------------------------------------------------------

runServer :: Int -> Map Text Operation -> IO ()
runServer port ops = scotty port $ do
  post (literal "/run") $ do
    req <- jsonData :: ActionM RunRequest
    let argsVal = case req.args of
                    Just v  -> v
                    Nothing -> Object KM.empty
    (code, body) <- liftIO $ handleRun req.op argsVal ops
    Scotty.status (mkStatus code "")
    json body

-- ---------------------------------------------------------------------------
-- isRunning
-- ---------------------------------------------------------------------------

isRunning :: Int -> IO Bool
isRunning port = do
  result <- try checkSocket :: IO (Either SomeException ())
  case result of
    Right () -> pure True
    Left _   -> pure False
  where
    checkSocket = do
      sock <- socket AF_INET Stream defaultProtocol
      let addr = SockAddrInet (fromIntegral port) (tupleToHostAddress (127, 0, 0, 1))
      connect sock addr `catch` (\e -> close sock >> ioError (userError (show (e :: SomeException))))
      close sock

-- ---------------------------------------------------------------------------
-- startServer
-- ---------------------------------------------------------------------------

startServer :: IO ()
startServer = do
  pidPath <- pidFilePath
  logPath <- logFilePath
  createDirectoryIfMissing True (takeDirectory pidPath)
  logHandle <- openFile logPath AppendMode
  let cp = (proc "claudespaces-bridge-server" [])
        { std_in  = NoStream
        , std_out = UseHandle logHandle
        , std_err = UseHandle logHandle
        , create_group = True
        }
  (_, _, _, ph) <- createProcess cp
  mPid <- getPid ph
  case mPid of
    Just pid -> writeFile pidPath (show pid <> "\n")
    Nothing  -> pure ()

getPid :: ProcessHandle -> IO (Maybe Int)
getPid ph = withProcessHandle ph go
  where
    go (OpenHandle pid)      = pure (Just (fromIntegral pid))
    go (OpenExtHandle pid _) = pure (Just (fromIntegral pid))
    go (ClosedHandle _)      = pure Nothing

-- ---------------------------------------------------------------------------
-- stopServerIfLast
-- ---------------------------------------------------------------------------

-- | Stop the host bridge server if no other workspaces remain running.
-- The current workspace name is excluded from the "running" check.
stopServerIfLast :: Text -> FilePath -> IO ()
stopServerIfLast currentName stateFile = do
  workspaces <- allWorkspaces stateFile
  let others = filter (\w -> w.name /= currentName && w.status == Running) workspaces
  when (null others) $ do
    pidFile <- pidFilePath
    killServer pidFile `catch` (\e -> case e of
      _ | isDoesNotExistError (e :: IOError) -> pure ()
        | otherwise -> pure ())

killServer :: FilePath -> IO ()
killServer pidFile = do
  contents <- readFile pidFile
  let pid = read (T.unpack (T.strip (T.pack contents))) :: Int
  signalProcess sigTERM (fromIntegral pid :: CPid)
  removeFile pidFile `catch` (\(_ :: IOError) -> pure ())
