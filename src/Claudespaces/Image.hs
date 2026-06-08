
module Claudespaces.Image
  ( sanitizeTag
  , intermediateTag
  , globalTag
  , customTag
  , imageExists
  , buildImage
  , hashSupportFiles
  , listDirectoryRecursive
  , resolveImage
  ) where

import           Data.List              (sort)
import           Data.Text              (Text)
import qualified Data.Text              as T
import qualified Data.ByteString        as BS
import qualified Data.ByteString.Char8  as BS8
import qualified Crypto.Hash.MD5        as MD5
import           System.Directory       (doesFileExist, listDirectory, doesDirectoryExist)
import           System.Exit            (ExitCode (..))
import           System.FilePath        ((</>))
import           System.IO.Error        (userError, ioError)
import           System.Process         (readProcessWithExitCode)
import           Text.Printf            (printf)

-- | Replace ':' and '/' with '-' in a Docker tag string.
sanitizeTag :: Text -> Text
sanitizeTag = T.map replace
  where
    replace ':' = '-'
    replace '/' = '-'
    replace c   = c

-- | Build an intermediate cache tag: "claudespaces-base:<sanitizedBase>-<hash>"
intermediateTag :: Text -> Text -> Text
intermediateTag baseTag hash =
  "claudespaces-base:" <> sanitizeTag baseTag <> "-" <> hash

-- | Compute "claudespaces-global:<hash12>" from dockerfile path and base image.
globalTag :: FilePath -> Text -> Text
globalTag dockerfilePath baseImage =
  "claudespaces-global:" <> md5Hex12 (dockerfilePath <> ":" <> T.unpack baseImage)

-- | Compute "claudespaces-custom:<hash12>" from dockerfile path and base image.
customTag :: FilePath -> Text -> Text
customTag dockerfilePath baseImage =
  "claudespaces-custom:" <> md5Hex12 (dockerfilePath <> ":" <> T.unpack baseImage)

-- | MD5 of input string, taking first 12 hex characters.
md5Hex12 :: String -> Text
md5Hex12 input =
  T.pack $ take 12 $ concatMap (printf "%02x") $ BS.unpack $ MD5.hash (BS8.pack input)

-- | Check whether a Docker image exists locally.
imageExists :: Text -> IO Bool
imageExists tag = do
  (code, _, _) <- readProcessWithExitCode "docker"
    ["image", "inspect", T.unpack tag] ""
  return $ code == ExitSuccess

-- | Build a Docker image with an optional base image build-arg.
buildImage :: Text -> FilePath -> FilePath -> Text -> IO ()
buildImage tag dockerfile context baseImage = do
  (code, _, err) <- readProcessWithExitCode "docker"
    [ "build"
    , "--build-arg", "BASE_IMAGE=" <> T.unpack baseImage
    , "-t", T.unpack tag
    , "-f", dockerfile
    , context
    ] ""
  case code of
    ExitSuccess   -> return ()
    ExitFailure _ -> ioError (userError $ "docker build failed: " <> err)

-- | Recursively list all files under a directory, sorted.
listDirectoryRecursive :: FilePath -> IO [FilePath]
listDirectoryRecursive dir = do
  entries <- listDirectory dir
  let fullPaths = map (dir </>) (sort entries)
  fmap (sort . concat) $ mapM expand fullPaths
  where
    expand path = do
      isDir <- doesDirectoryExist path
      if isDir
        then listDirectoryRecursive path
        else return [path]

-- | MD5 hash (12 hex chars) of the contents of all files under a directory.
hashSupportFiles :: FilePath -> IO Text
hashSupportFiles dir = do
  files   <- listDirectoryRecursive dir
  contents <- mapM BS.readFile files
  let combined = BS.concat contents
  return $ T.pack $ take 12 $ concatMap (printf "%02x") $ BS.unpack $ MD5.hash combined

-- | Resolve (and build if needed) the final Docker image to use.
-- Chains: base image -> global dockerfile -> local dockerfile -> claudespaces-base layer.
resolveImage
  :: Maybe Text      -- ^ mImage: explicit base image
  -> Maybe FilePath  -- ^ mGlobalDockerfile: path to global Dockerfile
  -> Maybe FilePath  -- ^ mDockerfile: path to project-local Dockerfile
  -> FilePath        -- ^ supportDir: directory with support files
  -> IO Text
resolveImage mImage mGlobalDockerfile mDockerfile supportDir = do
  -- Validate dockerfile paths exist
  mapM_ checkExists mGlobalDockerfile
  mapM_ checkExists mDockerfile

  let baseImage = maybe "ubuntu:24.04" id mImage
  supportHash <- hashSupportFiles supportDir

  -- Step 1: apply global dockerfile if provided
  afterGlobal <- case mGlobalDockerfile of
    Nothing -> return baseImage
    Just df -> do
      let tag = globalTag df baseImage
      exists <- imageExists tag
      if exists
        then return tag
        else do
          buildImage tag df supportDir baseImage
          return tag

  -- Step 2: apply local dockerfile if provided
  afterLocal <- case mDockerfile of
    Nothing -> return afterGlobal
    Just df -> do
      let tag = customTag df afterGlobal
      exists <- imageExists tag
      if exists
        then return tag
        else do
          buildImage tag df supportDir afterGlobal
          return tag

  -- Step 3: build the claudespaces-base layer
  let finalTag = intermediateTag afterLocal supportHash
  exists <- imageExists finalTag
  if exists
    then return finalTag
    else do
      -- Build using the support dir's entrypoint/Dockerfile
      let claudeDockerfile = supportDir </> "Dockerfile"
      buildImage finalTag claudeDockerfile supportDir afterLocal
      return finalTag

  where
    checkExists path = do
      ok <- doesFileExist path
      if ok
        then return ()
        else ioError (userError $ "Dockerfile not found: " <> path)
