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
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Hatter (newActionState, runActionM, createAction, createOnChange)
import Hatter.Ble
  ( BleScanResult(..)
  , BleAdapterStatus(..)
  , BleDeviceAddress(..)
  , emptyBleAdvertisement
  , parseBleAdvertisement
  )
import Hatter.Permission (PermissionStatus(..))
import Hatter.Widget
  ( ButtonConfig(..)
  , Color(..)
  , LayoutItem(..)
  , LayoutSettings(..)
  , TextConfig(..)
  , TextInputConfig(..)
  , Widget(..)
  , WidgetStyle(..)
  )
import KBeacon.Configure (BeaconTarget(..))
import KBeacon.Json
  ( JsonValue(..)
  , lookupField
  , jsonInt
  , parseJson
  , renderJson
  )
import KBeacon.OtaApp
  ( AppPage(..)
  , AppState(..)
  , DiscoveredBeacon(..)
  , RateVerdict(..)
  , appView
  , continuePastPermissions
  , defaultRssiThreshold
  , newAppState
  , onScanResultAt
  , rateVerdict
  , scanRefusalForAdapter
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
  , ScanIdentity(..)
  , identifyScanResult
  , kkmExtDataBattery
  , kkmExtDataMac
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
  , scanUiTests
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
  , testCase "identifies a KKM-prefixed address as a beacon" $
      assertEqual "identity"
        (KkmBeacon (BeaconMac (BS.pack [0xBC, 0x57, 0x29, 0x1A, 0x2B, 0x3C])))
        (identifyScanResult Nothing "BC:57:29:1A:2B:3C" "KBPro-1A2B3C")
  , testCase "accepts the static-random spelling of the KKM prefix" $
      assertEqual "identity"
        (KkmBeacon (BeaconMac (BS.pack [0xFC, 0x57, 0x29, 0xF4, 0xF5, 0xF6])))
        (identifyScanResult Nothing "FC:57:29:F4:F5:F6" "KBPro-F4F5F6")
  , testCase "the address verdict beats a KKM-looking name" $
      assertEqual "identity" ForeignDevice
        (identifyScanResult Nothing "AA:BB:CC:DD:EE:FF" "KBPro-1A2B3C")
  , testCase "falls back to the name on iOS-style addresses" $
      assertEqual "identity"
        (KkmBeacon (BeaconMac (BS.pack [0xBC, 0x57, 0x29, 0x1A, 0x2B, 0x3C])))
        (identifyScanResult Nothing "8B7A9E31-2C44-4A0F-9E7B-5D6F0A1B2C3D" "KBPro-1A2B3C")
  , testCase "cannot decide an iOS address without a factory name" $
      assertEqual "identity" IdentityUnknown
        (identifyScanResult Nothing "8B7A9E31-2C44-4A0F-9E7B-5D6F0A1B2C3D" "office speaker")
  , testCase "ext data outvotes a foreign MAC prefix" $
      assertEqual "identity"
        (KkmBeacon (BeaconMac (BS.pack [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])))
        (identifyScanResult (Just vectorExtData) "AA:BB:CC:DD:EE:FF" "")
  , testCase "ext data recovers the MAC of a renamed beacon on iOS" $
      assertEqual "identity"
        (KkmBeacon (BeaconMac (BS.pack [0xBC, 0x57, 0x29, 0x4D, 0x5E, 0x6F])))
        (identifyScanResult (Just vectorExtData)
          "8B7A9E31-2C44-4A0F-9E7B-5D6F0A1B2C3D" "conference room")
  , testCase "ext data battery is byte 0, clamped like KKM's parser" $ do
      assertEqual "battery" (Just 85) (kkmExtDataBattery vectorExtData)
      assertEqual "clamped" (Just 100)
        (kkmExtDataBattery (BS.pack [200, 0x00, 0x01]))
      assertEqual "too short" Nothing (kkmExtDataBattery (BS.pack [85, 0x00]))
  , testCase "the MAC marker gates the ext data MAC bytes" $ do
      assertEqual "marked" (Just (BeaconMac (BS.pack [0xBC, 0x57, 0x29, 0x4D, 0x5E, 0x6F])))
        (kkmExtDataMac vectorExtData)
      assertEqual "marker byte not 1" Nothing
        (kkmExtDataMac (BS.pack [85, 0x00, 0x00, 0x4D, 0x5E, 0x6F]))
      assertEqual "type flags not 0" Nothing
        (kkmExtDataMac (BS.pack [85, 0x04, 0x01, 0x4D, 0x5E, 0x6F]))
      assertEqual "too short" Nothing
        (kkmExtDataMac (BS.pack [85, 0x00, 0x01, 0x4D, 0x5E]))
  ]

-- | A KKM 0x2080 service data payload: battery 85, type flags 0, MAC
-- marker 1, low MAC bytes 4D 5E 6F.
vectorExtData :: ByteString
vectorExtData = BS.pack [85, 0x00, 0x01, 0x4D, 0x5E, 0x6F]

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

-- | Integration tests for the signal-to-UI path: the scan callback
-- the app registers with the platform ('onScanResultAt', clock
-- injected) is fed fabricated results, and the widget tree the app
-- registers as its view ('appView') must reflect them. The redraw
-- hook stands in for the platform's render loop, so the tests also
-- prove the app asks for a repaint when the list changed.
scanUiTests :: TestTree
scanUiTests = testGroup "scan signal to ui"
  [ testCase "a KBeacon signal adds a listed row with its battery" $ do
      (appState, repaints) <- newScannerAppState
      textsBefore <- renderedAppTexts appState
      assertBool "beacon must not be listed before the signal"
        (not (any (Text.isInfixOf "KBPro-4D5E6F") textsBefore))
      onScanResultAt 10 appState defaultRssiThreshold androidKBeaconSignal
      repaintCount <- readIORef repaints
      assertEqual "repaints after the signal" 1 repaintCount
      textsAfter <- renderedAppTexts appState
      assertBool "beacon row rendered after the signal"
        (any (Text.isInfixOf "KBPro-4D5E6F") textsAfter)
      assertBool "battery from the advertisement rendered"
        (any (Text.isInfixOf "85%") textsAfter)
      assertBool "device count reflects the discovery"
        (any (Text.isInfixOf "1 device(s) found") textsAfter)
  , testCase "a repeated advertisement refreshes the row, not duplicates it" $ do
      (appState, repaints) <- newScannerAppState
      onScanResultAt 10 appState defaultRssiThreshold androidKBeaconSignal
      onScanResultAt 11 appState defaultRssiThreshold
        androidKBeaconSignal { bsrRssi = -60 }
      beacons <- readIORef (stateBeacons appState)
      assertEqual "listed once" 1 (length beacons)
      assertEqual "rssi refreshed" [-60] (map beaconRssi beacons)
      repaintCount <- readIORef repaints
      assertEqual "repainted for both the listing and the refresh" 2 repaintCount
  , testCase "repeated advertisements measure the interval, smoothed" $ do
      (appState, _) <- newScannerAppState
      onScanResultAt 10 appState defaultRssiThreshold androidKBeaconSignal
      onScanResultAt 11 appState defaultRssiThreshold androidKBeaconSignal
      beaconsAfterTwo <- readIORef (stateBeacons appState)
      assertEqual "first measurement is the delta"
        [Just 1000] (map beaconIntervalMs beaconsAfterTwo)
      onScanResultAt 12.2 appState defaultRssiThreshold androidKBeaconSignal
      beaconsAfterThree <- readIORef (stateBeacons appState)
      assertEqual "smoothed three parts old, one part new"
        [Just 1050] (map beaconIntervalMs beaconsAfterThree)
  , testCase "the measured rate colors the row against the expected interval" $ do
      (appState, _) <- newScannerAppState
      writeIORef (stateAdvPeriodInput appState) "1000"
      onScanResultAt 10 appState defaultRssiThreshold androidKBeaconSignal
      colorsBefore <- fmap widgetTextColors (renderedAppWidget appState)
      assertEqual "no color before a measurement" 0 (length colorsBefore)
      onScanResultAt 11 appState defaultRssiThreshold androidKBeaconSignal
      colorsMatching <- fmap widgetTextColors (renderedAppWidget appState)
      assertEqual "one colored row at the expected rate" 1 (length colorsMatching)
      (slowState, _) <- newScannerAppState
      writeIORef (stateAdvPeriodInput slowState) "1000"
      onScanResultAt 10 slowState defaultRssiThreshold androidKBeaconSignal
      onScanResultAt 15 slowState defaultRssiThreshold androidKBeaconSignal
      colorsDeviating <- fmap widgetTextColors (renderedAppWidget slowState)
      assertEqual "one colored row at a deviating rate" 1 (length colorsDeviating)
      assertBool "matching and deviating rates color differently"
        (colorsMatching /= colorsDeviating)
  , testCase "rateVerdict tolerates jitter but flags another period" $ do
      assertEqual "exact" RateMatching
        (rateVerdict (validateAdvPeriod 1000) (Just 1000))
      assertEqual "within tolerance" RateMatching
        (rateVerdict (validateAdvPeriod 1000) (Just 1249))
      assertEqual "too slow" RateDeviating
        (rateVerdict (validateAdvPeriod 1000) (Just 1260))
      assertEqual "too fast" RateDeviating
        (rateVerdict (validateAdvPeriod 1000) (Just 700))
      assertEqual "no measurement" RateUnknown
        (rateVerdict (validateAdvPeriod 1000) Nothing)
      assertEqual "invalid expectation" RateUnknown
        (rateVerdict (Left "invalid") (Just 1000))
  , testCase "a weak signal stays out of the list until it strengthens" $ do
      (appState, repaints) <- newScannerAppState
      onScanResultAt 10 appState defaultRssiThreshold
        androidKBeaconSignal { bsrRssi = -80 }
      weakBeacons <- readIORef (stateBeacons appState)
      assertEqual "not listed while weak" 0 (length weakBeacons)
      weakRepaints <- readIORef repaints
      assertEqual "no repaint while weak" 0 weakRepaints
      onScanResultAt 11 appState defaultRssiThreshold androidKBeaconSignal
      strongBeacons <- readIORef (stateBeacons appState)
      assertEqual "listed once strong" 1 (length strongBeacons)
  , testCase "foreign hardware is never listed" $ do
      (appState, repaints) <- newScannerAppState
      onScanResultAt 10 appState defaultRssiThreshold BleScanResult
        { bsrDeviceName = "NotABeacon"
        , bsrDeviceAddress = BleDeviceAddress "F0:F1:F2:F3:F4:F5"
        , bsrRssi = -30
        , bsrAdvertisement = Right emptyBleAdvertisement
        }
      beacons <- readIORef (stateBeacons appState)
      assertEqual "not listed" 0 (length beacons)
      repaintCount <- readIORef repaints
      assertEqual "no repaint" 0 repaintCount
  , testCase "the netsim static-random KKM prefix is listed with its MAC" $ do
      (appState, _) <- newScannerAppState
      onScanResultAt 10 appState defaultRssiThreshold BleScanResult
        { bsrDeviceName = "KBPro-F4F5F6"
        , bsrDeviceAddress = BleDeviceAddress "FC:57:29:F4:F5:F6"
        , bsrRssi = -40
        , bsrAdvertisement = parseBleAdvertisement (BS.pack
            [ 0x02, 0x01, 0x06
            , 0x09, 0x16, 0x80, 0x20, 85, 0x00, 0x01, 0xF4, 0xF5, 0xF6
            ])
        }
      beacons <- readIORef (stateBeacons appState)
      assertEqual "auth mac from the advertised address"
        [Just (BeaconMac (BS.pack [0xFC, 0x57, 0x29, 0xF4, 0xF5, 0xF6]))]
        (map (targetMac . beaconTarget) beacons)
  , testCase "ext data lists a renamed beacon on iOS with its MAC" $ do
      (appState, _) <- newScannerAppState
      onScanResultAt 10 appState defaultRssiThreshold iosRenamedKBeaconSignal
      beacons <- readIORef (stateBeacons appState)
      assertEqual "auth mac recovered from the service data"
        [Just (BeaconMac (BS.pack [0xBC, 0x57, 0x29, 0x4D, 0x5E, 0x6F]))]
        (map (targetMac . beaconTarget) beacons)
  , testCase "a payload-less unnamed iOS callback waits for the name" $ do
      (appState, repaints) <- newScannerAppState
      onScanResultAt 10 appState defaultRssiThreshold
        iosNamedPayloadlessSignal { bsrDeviceName = "" }
      unnamedBeacons <- readIORef (stateBeacons appState)
      assertEqual "not listed without a name" 0 (length unnamedBeacons)
      onScanResultAt 11 appState defaultRssiThreshold iosNamedPayloadlessSignal
      beacons <- readIORef (stateBeacons appState)
      assertEqual "auth mac reconstructed from the name"
        [Just (BeaconMac (BS.pack [0xBC, 0x57, 0x29, 0x1A, 0x2B, 0x3C]))]
        (map (targetMac . beaconTarget) beacons)
      repaintCount <- readIORef repaints
      assertEqual "repainted for the named result" 1 repaintCount
  , testCase "the app opens on the permission page and grants move it on" $ do
      (appState, _) <- newCountingAppState
      textsBefore <- renderedAppTexts appState
      assertBool "permission button shown"
        (any (Text.isInfixOf "Request Permissions") textsBefore)
      assertBool "no scan controls yet"
        (not (any (Text.isInfixOf "Start Scan") textsBefore))
      continuePastPermissions appState PermissionGranted PermissionGranted
      page <- readIORef (statePage appState)
      assertEqual "page advanced" ScannerPage page
      textsAfter <- renderedAppTexts appState
      assertBool "scan controls shown"
        (any (Text.isInfixOf "Start Scan") textsAfter)
      assertBool "permission button gone"
        (not (any (Text.isInfixOf "Request Permissions") textsAfter))
  , testCase "a denied permission keeps the permission page up" $ do
      (appState, _) <- newCountingAppState
      continuePastPermissions appState PermissionGranted PermissionDenied
      page <- readIORef (statePage appState)
      assertEqual "page unchanged" PermissionPage page
      texts <- renderedAppTexts appState
      assertBool "status names the missing permission"
        (any (Text.isInfixOf "location permission denied") texts)
  , testCase "the scan button toggles with the scanning state" $ do
      (appState, _) <- newScannerAppState
      textsIdle <- renderedAppTexts appState
      assertBool "start shown while idle" (elem "Start Scan" textsIdle)
      assertBool "stop hidden while idle" (not (elem "Stop Scan" textsIdle))
      writeIORef (stateScanning appState) True
      textsScanning <- renderedAppTexts appState
      assertBool "stop shown while scanning" (elem "Stop Scan" textsScanning)
      assertBool "start hidden while scanning" (not (elem "Start Scan" textsScanning))
  , testCase "only an adapter that reports on may scan" $ do
      assertEqual "on scans" Nothing (scanRefusalForAdapter BleAdapterOn)
      assertBool "off refuses"
        (scanRefusalForAdapter BleAdapterOff /= Nothing)
      assertBool "unauthorized refuses"
        (scanRefusalForAdapter BleAdapterUnauthorized /= Nothing)
      assertBool "unsupported refuses"
        (scanRefusalForAdapter BleAdapterUnsupported /= Nothing)
  ]

-- | A KBeacon Pro advertisement as Android delivers it: the real MAC
-- with KKM's public OUI, flags plus 0x2080 service data (battery 85,
-- MAC marker, low MAC bytes 4D 5E 6F), well above
-- 'defaultRssiThreshold'.
androidKBeaconSignal :: BleScanResult
androidKBeaconSignal = BleScanResult
  { bsrDeviceName = "KBPro-4D5E6F"
  , bsrDeviceAddress = BleDeviceAddress "BC:57:29:4D:5E:6F"
  , bsrRssi = -42
  , bsrAdvertisement = parseBleAdvertisement (BS.pack
      [ 0x02, 0x01, 0x06
      , 0x09, 0x16, 0x80, 0x20, 85, 0x00, 0x01, 0x4D, 0x5E, 0x6F
      ])
  }

-- | A renamed KBeacon as iOS delivers it: opaque address, a name
-- that no longer encodes the MAC, but the 0x2080 service data
-- carries the MAC marker.
iosRenamedKBeaconSignal :: BleScanResult
iosRenamedKBeaconSignal = BleScanResult
  { bsrDeviceName = "meeting room"
  , bsrDeviceAddress = BleDeviceAddress "8B7A9E31-2C44-4A0F-9E7B-5D6F0A1B2C3D"
  , bsrRssi = -42
  , bsrAdvertisement = parseBleAdvertisement (BS.pack
      [ 0x02, 0x01, 0x06
      , 0x09, 0x16, 0x80, 0x20, 85, 0x00, 0x01, 0x4D, 0x5E, 0x6F
      ])
  }

-- | A factory-named KBeacon frame without any service data (e.g. an
-- Eddystone slot's frame) as iOS delivers it: only the name
-- identifies it.
iosNamedPayloadlessSignal :: BleScanResult
iosNamedPayloadlessSignal = BleScanResult
  { bsrDeviceName = "KBPro-1A2B3C"
  , bsrDeviceAddress = BleDeviceAddress "8B7A9E31-2C44-4A0F-9E7B-5D6F0A1B2C3D"
  , bsrRssi = -42
  , bsrAdvertisement = Right emptyBleAdvertisement
  }

-- | App state whose redraw hook counts repaints, standing in for the
-- platform's render loop; opens on the permission page like the real
-- app.
newCountingAppState :: IO (AppState, IORef Int)
newCountingAppState = do
  appState <- newAppState
  repaints <- newIORef (0 :: Int)
  writeIORef (stateRedraw appState) (modifyIORef' repaints (+ 1))
  pure (appState, repaints)

-- | 'newCountingAppState' already past the permission page, for the
-- scan tests.
newScannerAppState :: IO (AppState, IORef Int)
newScannerAppState = do
  (appState, repaints) <- newCountingAppState
  writeIORef (statePage appState) ScannerPage
  pure (appState, repaints)

-- | Render the app's view with inert button and input handles.
renderedAppWidget :: AppState -> IO Widget
renderedAppWidget appState = do
  actionState <- newActionState
  (inertAction, inertOnChange) <- runActionM actionState $ do
    action <- createAction (pure ())
    onChange <- createOnChange (\_ -> pure ())
    pure (action, onChange)
  appView appState
    inertAction inertAction inertAction inertAction inertAction
    inertOnChange inertOnChange inertOnChange

-- | Every text fragment the rendered view would display.
renderedAppTexts :: AppState -> IO [Text]
renderedAppTexts appState = fmap widgetTexts (renderedAppWidget appState)

-- | Every text fragment a widget tree renders: labels, button
-- captions, input values and hints, in tree order.
widgetTexts :: Widget -> [Text]
widgetTexts = \case
  Text config -> [tcLabel config]
  Button config -> [bcLabel config]
  TextInput config -> [tiValue config, tiHint config]
  Column settings -> concatMap (widgetTexts . liWidget) (lsWidgets settings)
  Row settings -> concatMap (widgetTexts . liWidget) (lsWidgets settings)
  Stack items -> concatMap (widgetTexts . liWidget) items
  Image _ -> []
  WebView _ -> []
  MapView _ -> []
  Styled _ inner -> widgetTexts inner
  Animated _ inner -> widgetTexts inner

-- | Every text-color override applied in a widget tree, in tree
-- order; how the rate coloring is observed.
widgetTextColors :: Widget -> [Color]
widgetTextColors = \case
  Text _ -> []
  Button _ -> []
  TextInput _ -> []
  Column settings -> concatMap (widgetTextColors . liWidget) (lsWidgets settings)
  Row settings -> concatMap (widgetTextColors . liWidget) (lsWidgets settings)
  Stack items -> concatMap (widgetTextColors . liWidget) items
  Image _ -> []
  WebView _ -> []
  MapView _ -> []
  Styled style inner -> case wsTextColor style of
    Just color -> color : widgetTextColors inner
    Nothing -> widgetTextColors inner
  Animated _ inner -> widgetTextColors inner
