{-# LANGUAGE OverloadedStrings #-}
-- | Unit tests for the pure KBeacon protocol layer.
--
-- The MD5 auth vectors were generated independently with Python's
-- hashlib from the algorithm in KKM's KBAuthHandler.java, so these
-- tests catch a mis-implementation of the digest input layout rather
-- than merely mirroring the Haskell code.
module Main where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import KBeacon.Json
  ( JsonValue(..)
  , lookupField
  , jsonInt
  , parseJson
  , renderJson
  )
import KBeacon.Protocol
  ( AdvSlot(..)
  , AppRandom(..)
  , AuthEvent(..)
  , AuthVariant(..)
  , BeaconMac(..)
  , BeaconNotification(..)
  , FragmentPosition(..)
  , FrameBudget(..)
  , JsonAck(..)
  , ParaInfo(..)
  , ReportAssembly
  , ReportFragment(..)
  , appendReportFragment
  , authPhase1Request
  , authPhase2Request
  , defaultBeaconPassword
  , emptyReportAssembly
  , encodeJsonRequestFrames
  , expectedDeviceProof
  , frameBudgetFromAttMtu
  , getParaRequestJson
  , macFromAddress
  , macFromName
  , macForAuthentication
  , negotiatedFrameBudget
  , parseBeaconNotification
  , parseParaResponse
  , reportAckFrame
  , setAdvPeriodJson
  , slotToConfigure
  , unReportAssembly
  , validateAdvPeriod
  , xorFoldDigest
  )
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase)

main :: IO ()
main = defaultMain (testGroup "kbeacon-ota"
  [ jsonTests
  , macTests
  , authTests
  , framingTests
  , notificationTests
  , reassemblyTests
  , messageTests
  ])

-- | The MAC used by the Python-generated auth vectors.
vectorMac :: BeaconMac
vectorMac = BeaconMac (BS.pack [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])

-- | The app random used by the Python-generated auth vectors.
vectorAppRandom :: ByteString
vectorAppRandom = BS.pack [0x12, 0x34, 0x56, 0x78]

-- | The device random used by the Python-generated auth vectors.
vectorDeviceRandom :: ByteString
vectorDeviceRandom = BS.pack [0xDE, 0xAD, 0xBE, 0xEF]

-- | hashlib.md5(bytes.fromhex("FFEEDDCCBBAA") + b"\xa9\xb1"
--   + b"\x12\x34\x56\x78" + b"0"*16).digest()
vectorPhase1Proof :: ByteString
vectorPhase1Proof = BS.pack
  [ 0x82, 0xfd, 0x5b, 0x28, 0xf2, 0x1c, 0x70, 0xb7
  , 0x27, 0x75, 0x5b, 0x53, 0xd9, 0xe8, 0x11, 0x3a
  ]

-- | XOR of the two 8-byte halves of 'vectorPhase1Proof'.
vectorPhase1Folded :: ByteString
vectorPhase1Folded = BS.pack [0xa5, 0x88, 0x00, 0x7b, 0x2b, 0xf4, 0x61, 0x8d]

-- | Same digest layout keyed on the device random.
vectorPhase2Proof :: ByteString
vectorPhase2Proof = BS.pack
  [ 0x0c, 0x36, 0xcb, 0xcc, 0xd3, 0xad, 0xda, 0xa7
  , 0x6a, 0xc6, 0x9c, 0xf5, 0x80, 0x9a, 0x1c, 0x7c
  ]

jsonTests :: TestTree
jsonTests = testGroup "json"
  [ testCase "renders the cfg message without spaces or floats" $
      assertEqual "rendered"
        "{\"msg\":\"cfg\",\"advObj\":[{\"type\":5,\"slot\":0,\"advPrd\":2000}]}"
        (renderJson (JsonObject
          [ ("msg", JsonString "cfg")
          , ("advObj", JsonArray
              [ JsonObject
                  [ ("type", JsonNumber 5)
                  , ("slot", JsonNumber 0)
                  , ("advPrd", JsonNumber 2000)
                  ]
              ])
          ]))
  , testCase "parses a realistic getPara response" $ do
      let raw = "{\"model\":\"K23\",\"btPt\":92,\"name\":\"KBPro-1A2B3C\",\
                \\"advObj\":[{\"type\":5,\"slot\":0,\"advPrd\":1280,\"txPwr\":0},\
                \{\"type\":2,\"slot\":1,\"advPrd\":2000}]}"
      case parseJson raw of
        Left err -> assertBool ("parse failed: " <> show err) False
        Right document -> do
          assertEqual "battery" (Just 92) (lookupField "btPt" document >>= jsonInt)
  , testCase "roundtrips escapes" $
      assertEqual "roundtrip"
        (Right (JsonObject [("a", JsonString "x\"y\\z\n")]))
        (parseJson (renderJson (JsonObject [("a", JsonString "x\"y\\z\n")])))
  , testCase "parses unicode escapes including surrogate pairs" $
      assertEqual "surrogate pair"
        (Right (JsonString "\x1F600"))
        (parseJson "\"\\uD83D\\uDE00\"")
  , testCase "rejects trailing garbage" $
      assertBool "should fail" (isLeft (parseJson "{} extra"))
  ]

macTests :: TestTree
macTests = testGroup "mac derivation"
  [ testCase "parses an Android address" $
      assertEqual "mac" (Just vectorMac) (macFromAddress "AA:BB:CC:DD:EE:FF")
  , testCase "rejects an iOS UUID address" $
      assertEqual "no mac" Nothing
        (macFromAddress "8B7A9E31-2C44-4A0F-9E7B-5D6F0A1B2C3D")
  , testCase "derives the MAC from a factory name via the KKM OUI" $
      assertEqual "mac"
        (Just (BeaconMac (BS.pack [0xBC, 0x57, 0x29, 0x1A, 0x2B, 0x3C])))
        (macFromName "KBPro-1A2B3C")
  , testCase "rejects names without a hex suffix" $
      assertEqual "no mac" Nothing (macFromName "office-beacon")
  , testCase "prefers the address over the name" $
      assertEqual "mac" (Just vectorMac)
        (macForAuthentication "AA:BB:CC:DD:EE:FF" "KBPro-1A2B3C")
  , testCase "falls back to the name on iOS-style addresses" $
      assertEqual "mac"
        (Just (BeaconMac (BS.pack [0xBC, 0x57, 0x29, 0x1A, 0x2B, 0x3C])))
        (macForAuthentication "8B7A9E31-2C44-4A0F-9E7B-5D6F0A1B2C3D" "KBPro-1A2B3C")
  ]

authTests :: TestTree
authTests = testGroup "auth handshake"
  [ testCase "phase 1 request layout" $
      assertEqual "frame"
        (BS.pack [0x13, 0x01, 0x12, 0x34, 0x56, 0x78, 0x00, 0x00, 0x00, 0x2A])
        (authPhase1Request (AppRandom vectorAppRandom) 42)
  , testCase "device proof matches the Python reference" $
      assertEqual "digest" vectorPhase1Proof
        (expectedDeviceProof vectorMac vectorAppRandom defaultBeaconPassword)
  , testCase "folded proof matches the Python reference" $
      assertEqual "folded" vectorPhase1Folded (xorFoldDigest vectorPhase1Proof)
  , testCase "phase 2 request carries the proof over the device random" $
      assertEqual "frame"
        (BS.pack [0x13, 0x02] <> vectorPhase2Proof)
        (authPhase2Request vectorMac vectorDeviceRandom defaultBeaconPassword AuthFullDigest)
  , testCase "short variant sends the folded proof under subtype 0x0C" $
      assertEqual "frame"
        (BS.pack [0x13, 0x0C] <> xorFoldDigest vectorPhase2Proof)
        (authPhase2Request vectorMac vectorDeviceRandom defaultBeaconPassword AuthShortDigest)
  , testCase "parses a phase 1 challenge notification" $
      assertEqual "event"
        (Right (AuthNotification
          (AuthChallenge AuthFullDigest vectorDeviceRandom vectorPhase1Proof)))
        (parseBeaconNotification
          (BS.pack [0x13, 0x01] <> vectorDeviceRandom <> vectorPhase1Proof))
  , testCase "parses the auth success notification with its MTU byte" $
      assertEqual "event"
        (Right (AuthNotification (AuthSucceeded 244)))
        (parseBeaconNotification (BS.pack [0x13, 0x02, 244]))
  , testCase "parses the auth failure notification" $
      assertEqual "event"
        (Right (AuthNotification AuthRejected))
        (parseBeaconNotification (BS.pack [0x13, 0xF1]))
  ]

framingTests :: TestTree
framingTests = testGroup "frame encoding"
  [ testCase "small messages become one single-tag frame" $
      assertEqual "frames"
        [BS.pack [0x23, 0x00, 0x00] <> "{\"a\":1}"]
        (encodeJsonRequestFrames (FrameBudget 17) "{\"a\":1}")
  , testCase "large messages fragment at the budget with byte offsets" $
      assertEqual "frames"
        [ BS.pack [0x20, 0x00, 0x00] <> BS.replicate 17 0x61
        , BS.pack [0x21, 0x00, 0x11] <> BS.replicate 17 0x61
        , BS.pack [0x22, 0x00, 0x22] <> BS.replicate 6 0x61
        ]
        (encodeJsonRequestFrames (FrameBudget 17) (BS.replicate 40 0x61))
  , testCase "fragments reassemble to the original message" $
      assertEqual "payload" (BS.replicate 40 0x61)
        (BS.concat (map (BS.drop 3) (encodeJsonRequestFrames (FrameBudget 17) (BS.replicate 40 0x61))))
  , testCase "auth MTU byte grows the budget" $
      assertEqual "budget" (FrameBudget 241) (frameBudgetFromAttMtu 247)
  , testCase "nonsense MTU keeps the default" $
      assertEqual "budget" (FrameBudget 17) (frameBudgetFromAttMtu 3)
  , testCase "negotiated budget is capped by the locally granted MTU" $
      assertEqual "budget" (FrameBudget 125) (negotiatedFrameBudget (Just 131) 247)
  , testCase "negotiated budget is capped by the beacon's report" $
      assertEqual "budget" (FrameBudget 241) (negotiatedFrameBudget (Just 512) 247)
  , testCase "failed local MTU negotiation keeps the default budget" $
      assertEqual "budget" (FrameBudget 17) (negotiatedFrameBudget Nothing 247)
  , testCase "absent beacon MTU report uses the default beacon bound" $
      assertEqual "budget" (FrameBudget 17) (negotiatedFrameBudget (Just 247) 0)
  , testCase "report ack frame layout" $
      assertEqual "frame"
        (BS.pack [0x33, 0x01, 0x02, 0x03, 0xE8, 0x00, 0x00])
        (reportAckFrame 258)
  ]

notificationTests :: TestTree
notificationTests = testGroup "notification parsing"
  [ testCase "parses a success ack with piggybacked payload" $
      assertEqual "ack"
        (Right (AckNotification (JsonAck 0 0 "{\"btPt\":92}")))
        (parseBeaconNotification
          (BS.pack [0x23, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00] <> "{\"btPt\":92}"))
  , testCase "parses an expect-next ack" $
      assertEqual "ack"
        (Right (AckNotification (JsonAck 17 4 "")))
        (parseBeaconNotification (BS.pack [0x23, 0x00, 0x11, 0x00, 0x01, 0x00, 0x04]))
  , testCase "parses a report fragment" $
      assertEqual "report"
        (Right (ReportNotification (ReportFragment 5 PositionEnd "abc")))
        (parseBeaconNotification (BS.pack [0x32, 0x00, 0x05] <> "abc"))
  , testCase "flags unknown data types instead of failing" $
      assertEqual "other"
        (Right (UnsupportedNotification 5))
        (parseBeaconNotification (BS.pack [0x53, 0x00, 0x00]))
  , testCase "rejects a truncated ack" $
      assertBool "should fail"
        (isLeft (parseBeaconNotification (BS.pack [0x23, 0x00])))
  ]

reassemblyTests :: TestTree
reassemblyTests = testGroup "report reassembly"
  [ testCase "in-order fragments build the full message" $ do
      let step1 = appendReportFragment emptyReportAssembly
            (ReportFragment 0 PositionStart "{\"btPt\"")
      case step1 of
        Left err -> assertBool ("step1 failed: " <> show err) False
        Right (partial, complete1) -> do
          assertEqual "not complete yet" False complete1
          case appendReportFragment partial (ReportFragment 7 PositionEnd ":92}") of
            Left err -> assertBool ("step2 failed: " <> show err) False
            Right (full, complete2) -> do
              assertEqual "complete" True complete2
              assertEqual "payload" (Right (ParaInfo (Just 92) []))
                (parseParaResponse (unAssembly full))
  , testCase "an offset mismatch is an error" $
      assertBool "should fail"
        (isLeft (appendReportFragment emptyReportAssembly
          (ReportFragment 3 PositionEnd "xyz")))
  ]

messageTests :: TestTree
messageTests = testGroup "config messages"
  [ testCase "getPara asks for common and adv parameters" $
      assertEqual "message"
        "{\"msg\":\"getPara\",\"type\":3}"
        getParaRequestJson
  , testCase "setAdvPeriod includes slot, type and period" $
      assertEqual "message"
        "{\"msg\":\"cfg\",\"advObj\":[{\"type\":5,\"slot\":0,\"advPrd\":1500}]}"
        (case validateAdvPeriod 1500 of
          Right period -> setAdvPeriodJson (AdvSlot 0 5 Nothing) period
          Left err -> error (show err))
  , testCase "rejects out-of-range periods" $ do
      assertBool "too small" (isLeft (validateAdvPeriod 99))
      assertBool "too large" (isLeft (validateAdvPeriod 40001))
  , testCase "parses the para response and picks slot 0" $ do
      let raw = "{\"btPt\":88,\"advObj\":[{\"type\":2,\"slot\":1,\"advPrd\":2000},\
                \{\"type\":5,\"slot\":0,\"advPrd\":1280}]}"
      case parseParaResponse raw of
        Left err -> assertBool ("parse failed: " <> show err) False
        Right para -> do
          assertEqual "battery" (Just 88) (paraBatteryPercent para)
          assertEqual "slot"
            (Right (AdvSlot 0 5 (Just 1280)))
            (slotToConfigure para)
  , testCase "falls back to the first slot when slot 0 is absent" $ do
      let raw = "{\"advObj\":[{\"type\":2,\"slot\":3}]}"
      case parseParaResponse raw of
        Left err -> assertBool ("parse failed: " <> show err) False
        Right para ->
          assertEqual "slot" (Right (AdvSlot 3 2 Nothing)) (slotToConfigure para)
  , testCase "no slots is an explicit error" $
      assertBool "should fail"
        (isLeft (parseParaResponse "{\"btPt\":50}" >>= slotToConfigure))
  ]

-- | Small local helper: is this Either a Left?
isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft (Right _) = False

-- | Unwrap the reassembly buffer for assertions.
unAssembly :: ReportAssembly -> ByteString
unAssembly = unReportAssembly
