-- | Executable shell around "KBeacon.OtaApp". The app itself lives in
-- the library so the test suite can drive its platform callbacks
-- (scan results in, widget tree out) directly.
module Main where

import Foreign.Ptr (Ptr)
import Hatter.AppContext (AppContext)
import KBeacon.OtaApp (otaAppMain)

main :: IO (Ptr AppContext)
main = otaAppMain
