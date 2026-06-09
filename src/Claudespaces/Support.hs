{-# LANGUAGE TemplateHaskell #-}

module Claudespaces.Support (withSupportDir) where

import qualified Data.ByteString as BS
import           Data.FileEmbed  (embedDir)
import           System.Directory (createDirectoryIfMissing)
import           System.FilePath  ((</>), takeDirectory)
import           System.IO.Temp   (withSystemTempDirectory)

embeddedSupport :: [(FilePath, BS.ByteString)]
embeddedSupport = $(embedDir "support")

withSupportDir :: (FilePath -> IO a) -> IO a
withSupportDir action =
  withSystemTempDirectory "claudespaces-support" $ \tmpDir -> do
    mapM_ (writeEntry tmpDir) embeddedSupport
    action tmpDir
  where
    writeEntry base (path, contents) = do
      let full = base </> path
      createDirectoryIfMissing True (takeDirectory full)
      BS.writeFile full contents
