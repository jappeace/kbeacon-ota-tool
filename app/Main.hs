{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE OverloadedStrings #-}
-- | KBeacon OTA tool: scan for nearby KBeacon Pro (KKM) beacons and
-- write a new advertisement interval to each of them, optionally
-- reporting every result to an HTTP endpoint.
--
-- The scan filters on KKM's 0x2080 service UUID, drops beacons below
-- a configurable RSSI threshold (the "proximity" idea of the original
-- Kotlin tool) and deduplicates by address. Configure All then walks
-- the discovered list with "KBeacon.Configure".
--
-- Action creation order matters: hatter's iOS simulator harness
-- (--autotest) fires UI event 0 after launch, which must be the
-- side-effect-free adapter check.
module Main where

import Data.ByteString qualified as ByteString
import Data.Char (intToDigit, toUpper)
import Data.IORef (IORef, newIORef, readIORef, writeIORef, modifyIORef')
import Data.Maybe (isJust, isNothing)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text, pack)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Text.Read qualified as TextRead
import Data.Word (Word8)
import Foreign.Ptr (Ptr)
import Hatter
  ( MobileApp(..)
  , UserState(..)
  , Action
  , OnChange
  , startMobileApp
  , platformLog
  , loggingMobileContext
  , newActionState
  , runActionM
  , createAction
  , createOnChange
  )
import Hatter.AppContext (AppContext(..), derefAppContext)
import Hatter.Ble
  ( BleScanResult(..)
  , BleDeviceAddress(..)
  , BleServiceUuid(..)
  , BleState
  , checkBleAdapter
  , startFilteredBleScan
  , stopBleScan
  )
import Hatter.Http
  ( HttpError
  , HttpMethod(..)
  , HttpRequest(..)
  , HttpResponse
  , HttpState
  , hrStatusCode
  , performRequest
  )
import Hatter.Permission (PermissionState, Permission(..), requestPermission)
import Hatter.Widget
  ( InputType(..)
  , TextInputConfig(..)
  , Widget(..)
  , column
  , row
  , scrollColumn
  , text
  , button
  )
import KBeacon.Configure
  ( BeaconOutcome(..)
  , BeaconSuccess(..)
  , BeaconTarget(..)
  , startConfigureSession
  )
import KBeacon.Json (JsonValue(..), jsonNumberFromInt, renderJson)
import KBeacon.Protocol
  ( AdvPeriodMs
  , defaultBeaconPassword
  , kbScanFilterServiceUuidText
  , macForAuthentication
  , unAdvPeriodMs
  , unBeaconMac
  , validateAdvPeriod
  )
import Unwitch.Convert.Word8 qualified as Word8

-- | One beacon in the UI list.
data DiscoveredBeacon = DiscoveredBeacon
  { beaconTarget :: BeaconTarget
  , beaconRssi :: Int
  , beaconStatus :: BeaconStatus
  , beaconReportNote :: Maybe Text
    -- ^ Outcome of the HTTP report for this beacon, when reporting is
    -- enabled.
  }

-- | Lifecycle of a listed beacon.
data BeaconStatus
  = StatusDiscovered
  | StatusConfiguring
  | StatusConfigured BeaconSuccess
  | StatusFailed Text

-- | All mutable app state, so the view function and the callbacks
-- share one handle.
data AppState = AppState
  { stateBeacons :: IORef [DiscoveredBeacon]
  , stateSeenAddresses :: IORef (Set Text)
  , stateAdvPeriodInput :: IORef Text
  , stateThresholdInput :: IORef Text
  , stateReportUrlInput :: IORef Text
  , stateScanning :: IORef Bool
  , stateConfiguring :: IORef Bool
  , stateStatusLine :: IORef Text
  , stateBle :: IORef (Maybe BleState)
  , statePermission :: IORef (Maybe PermissionState)
  , stateHttp :: IORef (Maybe HttpState)
  , stateRedraw :: IORef (IO ())
  }

-- | Default RSSI threshold, same -50 dBm proximity limit as the
-- original Kotlin Scanner.kt.
defaultRssiThreshold :: Int
defaultRssiThreshold = -50

main :: IO (Ptr AppContext)
main = do
  platformLog "kbeacon-ota starting"
  actionState <- newActionState
  appState <- newAppState

  (onCheckAdapter, onRequestPerms, onStartScan, onStopScan, onConfigureAll) <-
    runActionM actionState $ do
      -- Event id 0 (iOS --autotest): adapter check.
      checkAdapter <- createAction (checkAdapterAction appState)
      requestPerms <- createAction (requestPermissionsAction appState)
      startScan    <- createAction (startScanAction appState)
      stopScan     <- createAction (stopScanAction appState)
      configureAll <- createAction (configureAllAction appState)
      pure (checkAdapter, requestPerms, startScan, stopScan, configureAll)

  (onPeriodChange, onThresholdChange, onReportUrlChange) <-
    runActionM actionState $ do
      periodChange    <- createOnChange (writeIORef (stateAdvPeriodInput appState))
      thresholdChange <- createOnChange (writeIORef (stateThresholdInput appState))
      reportUrlChange <- createOnChange (writeIORef (stateReportUrlInput appState))
      pure (periodChange, thresholdChange, reportUrlChange)

  ctxPtr <- startMobileApp MobileApp
    { maContext     = loggingMobileContext
    , maView        = \userState -> do
        writeIORef (stateRedraw appState) (userRequestRedraw userState)
        appView appState
          onCheckAdapter onRequestPerms onStartScan onStopScan onConfigureAll
          onPeriodChange onThresholdChange onReportUrlChange
    , maActionState = actionState
    }

  appCtx <- derefAppContext ctxPtr
  writeIORef (stateBle appState) (Just (acBleState appCtx))
  writeIORef (statePermission appState) (Just (acPermissionState appCtx))
  writeIORef (stateHttp appState) (Just (acHttpState appCtx))
  pure ctxPtr

-- | Allocate the app state with its defaults.
newAppState :: IO AppState
newAppState = do
  beacons <- newIORef []
  seen <- newIORef Set.empty
  advPeriod <- newIORef "1000"
  threshold <- newIORef (pack (show defaultRssiThreshold))
  reportUrl <- newIORef ""
  scanning <- newIORef False
  configuring <- newIORef False
  statusLine <- newIORef "ready"
  ble <- newIORef Nothing
  permission <- newIORef Nothing
  http <- newIORef Nothing
  redraw <- newIORef (pure ())
  pure AppState
    { stateBeacons = beacons
    , stateSeenAddresses = seen
    , stateAdvPeriodInput = advPeriod
    , stateThresholdInput = threshold
    , stateReportUrlInput = reportUrl
    , stateScanning = scanning
    , stateConfiguring = configuring
    , stateStatusLine = statusLine
    , stateBle = ble
    , statePermission = permission
    , stateHttp = http
    , stateRedraw = redraw
    }

-- | Set the one-line status and repaint.
setStatus :: AppState -> Text -> IO ()
setStatus appState message = do
  platformLog message
  writeIORef (stateStatusLine appState) message
  requestRepaint appState

-- | Trigger a UI rebuild from a callback.
requestRepaint :: AppState -> IO ()
requestRepaint appState = do
  repaint <- readIORef (stateRedraw appState)
  repaint

-- | Adapter check (iOS autotest event 0).
checkAdapterAction :: AppState -> IO ()
checkAdapterAction appState = do
  status <- checkBleAdapter
  setStatus appState ("BLE adapter: " <> pack (show status))

-- | Request the BLE permission set hatter exposes from Haskell.
-- BLUETOOTH_CONNECT (needed by connectGatt on API 31 and later) is
-- not reachable through Hatter.Permission; MainActivity.onCreate
-- requests it natively at startup.
requestPermissionsAction :: AppState -> IO ()
requestPermissionsAction appState = do
  mPermissionState <- readIORef (statePermission appState)
  case mPermissionState of
    Nothing -> setStatus appState "permission state not ready"
    Just permissionState ->
      requestPermission permissionState PermissionBluetooth $ \bluetoothStatus -> do
        platformLog ("BLUETOOTH_SCAN permission: " <> pack (show bluetoothStatus))
        requestPermission permissionState PermissionLocation $ \locationStatus ->
          platformLog ("ACCESS_FINE_LOCATION permission: " <> pack (show locationStatus))

-- | Start the KKM-filtered scan with RSSI threshold and dedup.
startScanAction :: AppState -> IO ()
startScanAction appState = do
  mBleState <- readIORef (stateBle appState)
  thresholdText <- readIORef (stateThresholdInput appState)
  case (mBleState, parseRssiThreshold thresholdText) of
    (Nothing, _) -> setStatus appState "BLE state not ready"
    (Just _, Left thresholdError) -> setStatus appState thresholdError
    (Just bleState, Right threshold) -> do
      writeIORef (stateBeacons appState) []
      writeIORef (stateSeenAddresses appState) Set.empty
      writeIORef (stateScanning appState) True
      startFilteredBleScan bleState kbScanFilterService
        (onScanResult appState threshold)
      setStatus appState
        ("scanning for KBeacons (RSSI over " <> pack (show threshold) <> " dBm)")

-- | The KKM ext-data service UUID as a hatter value.
kbScanFilterService :: BleServiceUuid
kbScanFilterService = BleServiceUuid kbScanFilterServiceUuidText

-- | Parse the RSSI threshold input. Refuses to scan on nonsense
-- rather than guessing a value.
parseRssiThreshold :: Text -> Either Text Int
parseRssiThreshold input =
  case TextRead.signed TextRead.decimal (Text.strip input) of
    Right (threshold, rest) ->
      if Text.null rest && threshold >= -127 && threshold <= 20
        then Right threshold
        else Left ("invalid RSSI threshold: " <> input)
    Left _ -> Left ("invalid RSSI threshold: " <> input)

-- | Scan callback: threshold filter and dedup, mirroring the original
-- Scanner.kt behaviour (including its log lines).
onScanResult :: AppState -> Int -> BleScanResult -> IO ()
onScanResult appState threshold result = do
  let address = unBleDeviceAddress (bsrDeviceAddress result)
      rssi = bsrRssi result
  if rssi < threshold
    then platformLog ("ignored " <> address <> " rssi=" <> pack (show rssi))
    else do
      seen <- readIORef (stateSeenAddresses appState)
      if Set.member address seen
        then upgradeDiscoveredBeacon appState result
        else do
          modifyIORef' (stateSeenAddresses appState) (Set.insert address)
          modifyIORef' (stateBeacons appState) (\beacons -> DiscoveredBeacon
            { beaconTarget = scanResultTarget result
            , beaconRssi = rssi
            , beaconStatus = StatusDiscovered
            , beaconReportNote = Nothing
            } : beacons)
          platformLog ("found beacon " <> bsrDeviceName result
            <> " " <> address <> " rssi=" <> pack (show rssi))
          requestRepaint appState

-- | Build the configure target for one scan result.
scanResultTarget :: BleScanResult -> BeaconTarget
scanResultTarget result = BeaconTarget
  { targetName = bsrDeviceName result
  , targetAddress = bsrDeviceAddress result
  , targetMac = macForAuthentication
      (unBleDeviceAddress (bsrDeviceAddress result))
      (bsrDeviceName result)
  }

-- | A repeated scan result for a known address can carry information
-- the first one lacked: on iOS the device name (which the auth MAC is
-- derived from) travels in the scan response and is often missing
-- from the first callback. Replace the stored entry when the new
-- result supplies the MAC the stored one is missing.
upgradeDiscoveredBeacon :: AppState -> BleScanResult -> IO ()
upgradeDiscoveredBeacon appState result = do
  let address = unBleDeviceAddress (bsrDeviceAddress result)
      upgraded = scanResultTarget result
  beacons <- readIORef (stateBeacons appState)
  let entryNeedsUpgrade beacon =
        unBleDeviceAddress (targetAddress (beaconTarget beacon)) == address
          && isNothing (targetMac (beaconTarget beacon))
          && isJust (targetMac upgraded)
  if any entryNeedsUpgrade beacons
    then do
      modifyIORef' (stateBeacons appState) (map (\beacon ->
        if entryNeedsUpgrade beacon
          then beacon
            { beaconTarget = upgraded
            , beaconRssi = bsrRssi result
            }
          else beacon))
      platformLog ("upgraded " <> address <> " with name " <> bsrDeviceName result)
      requestRepaint appState
    else platformLog ("already seen " <> address)

-- | Stop scanning.
stopScanAction :: AppState -> IO ()
stopScanAction appState = do
  mBleState <- readIORef (stateBle appState)
  case mBleState of
    Nothing -> pure ()
    Just bleState -> do
      stopBleScan bleState
      writeIORef (stateScanning appState) False
      setStatus appState "scan stopped"

-- | Kick off the sequential configuration of every listed beacon.
configureAllAction :: AppState -> IO ()
configureAllAction appState = do
  mBleState <- readIORef (stateBle appState)
  periodText <- readIORef (stateAdvPeriodInput appState)
  alreadyConfiguring <- readIORef (stateConfiguring appState)
  beacons <- readIORef (stateBeacons appState)
  if alreadyConfiguring
    then setStatus appState "configuration already running"
    else case (mBleState, parseAdvPeriod periodText, beacons) of
      (Nothing, _, _) -> setStatus appState "BLE state not ready"
      (Just _, Left periodError, _) -> setStatus appState periodError
      (Just _, Right _, []) -> setStatus appState "no beacons discovered yet"
      (Just bleState, Right period, discovered) -> do
        stopBleScan bleState
        writeIORef (stateScanning appState) False
        writeIORef (stateConfiguring appState) True
        writeIORef (stateBeacons appState) (map markBeaconConfiguring discovered)
        setStatus appState
          ("configuring " <> pack (show (length discovered)) <> " beacon(s) to "
            <> pack (show (unAdvPeriodMs period)) <> " ms")
        let targets = map beaconTarget (reverse discovered)
        startConfigureSession bleState period defaultBeaconPassword targets
          platformLog
          (onBeaconOutcome appState)
          (onConfigureFinished appState)

-- | Reset a row to the configuring state at session start.
markBeaconConfiguring :: DiscoveredBeacon -> DiscoveredBeacon
markBeaconConfiguring beacon = beacon { beaconStatus = StatusConfiguring }

-- | Parse and validate the advertisement period input.
parseAdvPeriod :: Text -> Either Text AdvPeriodMs
parseAdvPeriod input =
  case TextRead.decimal (Text.strip input) of
    Right (period, rest) ->
      if Text.null rest
        then validateAdvPeriod period
        else Left ("invalid advertisement period: " <> input)
    Left _ -> Left ("invalid advertisement period: " <> input)

-- | Per-beacon result: update the list and send the HTTP report.
onBeaconOutcome :: AppState -> BeaconOutcome -> IO ()
onBeaconOutcome appState outcome = do
  let address = unBleDeviceAddress (targetAddress (outcomeTarget outcome))
      newStatus = case outcomeResult outcome of
        Right success -> StatusConfigured success
        Left failure -> StatusFailed failure
  modifyIORef' (stateBeacons appState) (map (\beacon ->
    if unBleDeviceAddress (targetAddress (beaconTarget beacon)) == address
      then beacon { beaconStatus = newStatus }
      else beacon))
  case outcomeResult outcome of
    Right success -> platformLog ("configured " <> address <> " to "
      <> pack (show (unAdvPeriodMs (successAppliedPeriod success))) <> " ms")
    Left failure -> platformLog ("configuration failed for " <> address <> ": " <> failure)
  requestRepaint appState
  reportOutcome appState outcome

-- | POST the outcome to the report URL, when one is set.
reportOutcome :: AppState -> BeaconOutcome -> IO ()
reportOutcome appState outcome = do
  url <- readIORef (stateReportUrlInput appState)
  mHttpState <- readIORef (stateHttp appState)
  if Text.null (Text.strip url)
    then pure ()
    else case mHttpState of
      Nothing -> platformLog "http state not ready, skipping report"
      Just httpState ->
        performRequest httpState HttpRequest
          { hrMethod = HttpPost
          , hrUrl = Text.strip url
          , hrHeaders = [("Content-Type", "application/json")]
          , hrBody = TextEncoding.encodeUtf8 (renderJson (outcomeReportJson outcome))
          }
          (onReportResult appState outcome)

-- | JSON body of a report: enough to identify the beacon and judge
-- the result (the original tool also flagged batteries under 98%).
outcomeReportJson :: BeaconOutcome -> JsonValue
outcomeReportJson outcome =
  let target = outcomeTarget outcome
      macText = case targetMac target of
        Just mac -> formatMacBytes (unBeaconMac mac)
        Nothing -> ""
      common =
        [ ("name", JsonString (targetName target))
        , ("address", JsonString (unBleDeviceAddress (targetAddress target)))
        , ("mac", JsonString macText)
        ]
  in case outcomeResult outcome of
    Right success -> JsonObject (common ++
      [ ("ok", JsonBool True)
      , ("advPeriodMs", jsonNumberFromInt (unAdvPeriodMs (successAppliedPeriod success)))
      , ("batteryPercent", case successBatteryPercent success of
          Just percent -> jsonNumberFromInt percent
          Nothing -> JsonNull)
      , ("batteryWarning", JsonBool (case successBatteryPercent success of
          Just percent -> percent < 98
          Nothing -> False))
      ])
    Left failure -> JsonObject (common ++
      [ ("ok", JsonBool False)
      , ("error", JsonString failure)
      ])

-- | Print MAC bytes as "AA:BB:CC:DD:EE:FF".
formatMacBytes :: ByteString.ByteString -> Text
formatMacBytes bytes =
  Text.intercalate ":" (map formatMacByte (ByteString.unpack bytes))

-- | Two uppercase hex digits for one byte.
formatMacByte :: Word8 -> Text
formatMacByte byte =
  let (high, low) = Word8.toInt byte `divMod` 16
  in pack [toUpper (intToDigit high), toUpper (intToDigit low)]

-- | Note the report delivery result on the beacon's row.
onReportResult :: AppState -> BeaconOutcome -> Either HttpError HttpResponse -> IO ()
onReportResult appState outcome result = do
  let address = unBleDeviceAddress (targetAddress (outcomeTarget outcome))
      note = case result of
        Right response -> "report sent (HTTP " <> pack (show (hrStatusCode response)) <> ")"
        Left httpError -> "report failed: " <> pack (show httpError)
  platformLog (address <> ": " <> note)
  modifyIORef' (stateBeacons appState) (map (\beacon ->
    if unBleDeviceAddress (targetAddress (beaconTarget beacon)) == address
      then beacon { beaconReportNote = Just note }
      else beacon))
  requestRepaint appState

-- | Session complete.
onConfigureFinished :: AppState -> IO ()
onConfigureFinished appState = do
  writeIORef (stateConfiguring appState) False
  setStatus appState "configuration finished"

-- | Build the widget tree from the current state.
appView
  :: AppState
  -> Action -> Action -> Action -> Action -> Action
  -> OnChange -> OnChange -> OnChange
  -> IO Widget
appView appState
        onCheckAdapter onRequestPerms onStartScan onStopScan onConfigureAll
        onPeriodChange onThresholdChange onReportUrlChange = do
  beacons <- readIORef (stateBeacons appState)
  advPeriod <- readIORef (stateAdvPeriodInput appState)
  threshold <- readIORef (stateThresholdInput appState)
  reportUrl <- readIORef (stateReportUrlInput appState)
  scanning <- readIORef (stateScanning appState)
  statusLine <- readIORef (stateStatusLine appState)
  pure (column
    [ row
        [ button "Check Adapter" onCheckAdapter
        , button "Request Permissions" onRequestPerms
        ]
    , TextInput TextInputConfig
        { tiInputType  = InputNumber
        , tiHint       = "Adv interval (ms)"
        , tiValue      = advPeriod
        , tiOnChange   = onPeriodChange
        , tiFontConfig = Nothing
        , tiAutoFocus  = False
        }
    , TextInput TextInputConfig
        { tiInputType  = InputText
        , tiHint       = "RSSI threshold (dBm)"
        , tiValue      = threshold
        , tiOnChange   = onThresholdChange
        , tiFontConfig = Nothing
        , tiAutoFocus  = False
        }
    , TextInput TextInputConfig
        { tiInputType  = InputText
        , tiHint       = "Report URL (optional)"
        , tiValue      = reportUrl
        , tiOnChange   = onReportUrlChange
        , tiFontConfig = Nothing
        , tiAutoFocus  = False
        }
    , row
        [ button "Start Scan" onStartScan
        , button "Stop Scan" onStopScan
        , button "Configure All" onConfigureAll
        ]
    , text ("Status: " <> statusLine)
    , text ("Scanning: " <> (if scanning then "yes" else "no")
        <> " | " <> pack (show (length beacons)) <> " device(s) found")
    , scrollColumn (map beaconRow (reverse beacons))
    ])

-- | One row per discovered beacon.
beaconRow :: DiscoveredBeacon -> Widget
beaconRow beacon =
  let target = beaconTarget beacon
      statusText = case beaconStatus beacon of
        StatusDiscovered -> "discovered"
        StatusConfiguring -> "configuring..."
        StatusConfigured success ->
          "set to " <> pack (show (unAdvPeriodMs (successAppliedPeriod success))) <> " ms"
            <> (case successBatteryPercent success of
                 Just percent -> ", battery " <> pack (show percent) <> "%"
                 Nothing -> "")
        StatusFailed failure -> "failed: " <> failure
      reportText = case beaconReportNote beacon of
        Just note -> " | " <> note
        Nothing -> ""
  in column
    [ row
        [ text (targetName target)
        , text (" | " <> unBleDeviceAddress (targetAddress target))
        , text (" | RSSI: " <> pack (show (beaconRssi beacon)))
        ]
    , text ("   " <> statusText <> reportText)
    ]
