{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE OverloadedStrings #-}
-- | KBeacon OTA tool: scan for nearby KBeacon Pro (KKM) beacons and
-- write a new advertisement interval to each of them, optionally
-- reporting every result to an HTTP endpoint.
--
-- The app opens on a permission page; once both runtime permissions
-- are granted it moves to the scanner page and the permission UI is
-- gone. The scan runs unfiltered and identifies KKM beacons by their
-- 0x2080 service data (with MAC-prefix and factory-name fallbacks,
-- see 'identifyScanResult'), drops beacons below a configurable RSSI
-- threshold (the "proximity" idea of the original Kotlin tool) and
-- deduplicates by address. Repeated advertisements refresh a listed
-- beacon's RSSI and battery and measure its actual advertisement
-- interval, which colors the row green or red against the expected
-- interval input. Configure All then walks the discovered list with
-- "KBeacon.Configure".
--
-- Action creation order matters: hatter's iOS simulator harness
-- (--autotest) fires UI event 0 after launch, which must be the
-- side-effect-free adapter check.
--
-- Decision: the app lives in the library instead of the executable so
-- the test suite can drive the exact functions the platform calls:
-- 'onScanResultAt' is the registered scan callback (with the clock
-- injected) and 'appView' the registered view builder, and the
-- signal-to-UI integration tests feed one and inspect the other.
-- @app/Main.hs@ only re-exports 'otaAppMain'.
module KBeacon.OtaApp
  ( -- * Entry point
    otaAppMain
    -- * App state
  , AppState(..)
  , AppPage(..)
  , DiscoveredBeacon(..)
  , BeaconStatus(..)
  , newAppState
  , defaultRssiThreshold
    -- * Platform callbacks (drivable from tests)
  , onScanResult
  , onScanResultAt
  , appView
    -- * Pure decision helpers
  , continuePastPermissions
  , scanRefusalForAdapter
  , RateVerdict(..)
  , rateVerdict
  ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Char (intToDigit, toUpper)
import Data.IORef (IORef, newIORef, readIORef, writeIORef, modifyIORef')
import Data.List (sortBy)
import Data.Ord (Down(..), comparing)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text, pack)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Text.Read qualified as TextRead
import Data.Time.Clock.POSIX (POSIXTime, getPOSIXTime)
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
  , BleAdapterStatus(..)
  , BleAdvertisementWithErrors(..)
  , BleDeviceAddress(..)
  , BleState
  , checkBleAdapter
  , serviceDataForUuid
  , startBleScan
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
import Hatter.Permission
  ( PermissionState
  , Permission(..)
  , PermissionStatus(..)
  , checkPermission
  , requestPermission
  )
import Hatter.Widget
  ( Color(..)
  , InputType(..)
  , TextInputConfig(..)
  , Widget(..)
  , coloredText
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
  , BeaconMac
  , ScanIdentity(..)
  , defaultBeaconPassword
  , identifyScanResult
  , kkmExtDataBattery
  , kkmExtDataServiceUuid
  , unAdvPeriodMs
  , unBeaconMac
  , validateAdvPeriod
  )
import Unwitch.Convert.Word8 qualified as Word8

-- | Which page the app shows. Permissions are dealt with once, on
-- their own page; after that only the scanner is on screen.
data AppPage
  = PermissionPage
  | ScannerPage
  deriving (Show, Eq)

-- | One beacon in the UI list.
data DiscoveredBeacon = DiscoveredBeacon
  { beaconTarget :: BeaconTarget
  , beaconRssi :: Int
  , beaconBattery :: Maybe Int
    -- ^ Battery percent broadcast in the 0x2080 service data, when
    -- the advertisement carried one.
  , beaconLastSeenAt :: POSIXTime
    -- ^ Arrival time of the latest advertisement, feeding the
    -- interval measurement.
  , beaconIntervalMs :: Maybe Int
    -- ^ Measured advertisement interval (smoothed), Nothing until a
    -- second advertisement arrives.
  , beaconStatus :: BeaconStatus
  , beaconReportNote :: Maybe Text
    -- ^ Outcome of the HTTP report for this beacon, when reporting is
    -- enabled.
  }

-- | Lifecycle of a listed beacon.
data BeaconStatus
  = StatusFound
  | StatusConfiguring
  | StatusConfigured BeaconSuccess
  | StatusFailed Text

-- | All mutable app state, so the view function and the callbacks
-- share one handle.
data AppState = AppState
  { statePage :: IORef AppPage
  , statePermissionProbed :: IORef Bool
    -- ^ Whether the first render already asked the platform if the
    -- permissions are granted (the probe must run exactly once).
  , stateBeacons :: IORef [DiscoveredBeacon]
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

-- | Build the mobile app and hand its context to hatter's platform
-- harness.
otaAppMain :: IO (Ptr AppContext)
otaAppMain = do
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
  page <- newIORef PermissionPage
  permissionProbed <- newIORef False
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
    { statePage = page
    , statePermissionProbed = permissionProbed
    , stateBeacons = beacons
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

-- | Request the BLE permission set hatter exposes from Haskell, then
-- leave the permission page when both are granted.
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
        requestPermission permissionState PermissionLocation $ \locationStatus -> do
          platformLog ("ACCESS_FINE_LOCATION permission: " <> pack (show locationStatus))
          continuePastPermissions appState bluetoothStatus locationStatus

-- | Move to the scanner page when both permissions are granted; a
-- denied permission keeps the permission page up with a status
-- saying which one is missing.
continuePastPermissions :: AppState -> PermissionStatus -> PermissionStatus -> IO ()
continuePastPermissions appState bluetoothStatus locationStatus =
  case (bluetoothStatus, locationStatus) of
    (PermissionGranted, PermissionGranted) -> do
      writeIORef (statePage appState) ScannerPage
      setStatus appState "permissions granted"
    (PermissionDenied, PermissionDenied) ->
      setStatus appState "bluetooth scan and location permissions denied"
    (PermissionDenied, PermissionGranted) ->
      setStatus appState "bluetooth scan permission denied"
    (PermissionGranted, PermissionDenied) ->
      setStatus appState "location permission denied"

-- | Why a scan cannot start given this adapter state; only an
-- adapter that reports on can scan.
scanRefusalForAdapter :: BleAdapterStatus -> Maybe Text
scanRefusalForAdapter status = case status of
  BleAdapterOn -> Nothing
  BleAdapterOff -> Just "bluetooth is off, turn it on to scan"
  BleAdapterUnauthorized -> Just "bluetooth permission missing, cannot scan"
  BleAdapterUnsupported -> Just "this device does not support bluetooth LE"

-- | Start the unfiltered scan after checking the adapter;
-- 'onScanResultAt' gates on KKM identity, the RSSI threshold and
-- dedup.
startScanAction :: AppState -> IO ()
startScanAction appState = do
  adapterStatus <- checkBleAdapter
  case scanRefusalForAdapter adapterStatus of
    Just refusal -> setStatus appState refusal
    Nothing -> do
      mBleState <- readIORef (stateBle appState)
      thresholdText <- readIORef (stateThresholdInput appState)
      case (mBleState, parseRssiThreshold thresholdText) of
        (Nothing, _) -> setStatus appState "BLE state not ready"
        (Just _, Left thresholdError) -> setStatus appState thresholdError
        (Just bleState, Right threshold) -> do
          writeIORef (stateBeacons appState) []
          writeIORef (stateSeenAddresses appState) Set.empty
          writeIORef (stateScanning appState) True
          startBleScan bleState (onScanResult appState threshold)
          setStatus appState
            ("scanning for KBeacons (RSSI over " <> pack (show threshold) <> " dBm)")

-- | Parse the RSSI threshold input. Refuses to scan on nonsense
-- rather than guessing a value. The accepted range is the full signed
-- byte (-128..127 dBm): real RSSI is negative, but virtual radios
-- (the Android emulator's netsim reports a fixed +20) and very close
-- devices can report positive values, and the threshold must be able
-- to sit above them to filter them out.
parseRssiThreshold :: Text -> Either Text Int
parseRssiThreshold input =
  case TextRead.signed TextRead.decimal (Text.strip input) of
    Right (threshold, rest) ->
      if Text.null rest && threshold >= -128 && threshold <= 127
        then Right threshold
        else Left ("invalid RSSI threshold: " <> input)
    Left _ -> Left ("invalid RSSI threshold: " <> input)

-- | The scan callback as registered with the platform: stamps the
-- arrival time and hands over to 'onScanResultAt'.
onScanResult :: AppState -> Int -> BleScanResult -> IO ()
onScanResult appState threshold result = do
  now <- getPOSIXTime
  onScanResultAt now appState threshold result

-- | Scan callback body: KKM identity gate, then the RSSI threshold
-- and dedup of the original Scanner.kt (including its log lines).
--
-- The scan is unfiltered, so this fires for every BLE device in
-- range and must stay quiet about them: an address already judged
-- foreign returns silently, a fresh foreign device is logged once
-- when its address is remembered, and a repeated advertisement from
-- a listed beacon refreshes that beacon ('refreshBeaconSighting')
-- instead of being dropped. A weak KBeacon is NOT remembered: its
-- signal fluctuates, so a later stronger advertisement must still be
-- able to list it. An undecidable result (opaque iOS address, no
-- name or MAC marker yet) is dropped without memory because a later
-- callback may carry what identifies it.
onScanResultAt :: POSIXTime -> AppState -> Int -> BleScanResult -> IO ()
onScanResultAt now appState threshold result = do
  let address = unBleDeviceAddress (bsrDeviceAddress result)
      rssi = bsrRssi result
      extData = scanResultExtData result
  seen <- readIORef (stateSeenAddresses appState)
  if Set.member address seen
    then refreshBeaconSighting now appState result extData
    else case identifyScanResult extData address (bsrDeviceName result) of
      IdentityUnknown -> pure ()
      ForeignDevice -> do
        modifyIORef' (stateSeenAddresses appState) (Set.insert address)
        platformLog ("not a KBeacon, skipping " <> address)
      KkmBeacon mac ->
        if rssi < threshold
          then platformLog ("ignored " <> address <> " rssi=" <> pack (show rssi))
          else do
            modifyIORef' (stateSeenAddresses appState) (Set.insert address)
            modifyIORef' (stateBeacons appState) (\beacons -> DiscoveredBeacon
              { beaconTarget = scanResultTarget mac result
              , beaconRssi = rssi
              , beaconBattery = extData >>= kkmExtDataBattery
              , beaconLastSeenAt = now
              , beaconIntervalMs = Nothing
              , beaconStatus = StatusFound
              , beaconReportNote = Nothing
              } : beacons)
            platformLog ("found beacon " <> bsrDeviceName result
              <> " " <> address <> " rssi=" <> pack (show rssi))
            requestRepaint appState

-- | KKM's 0x2080 service data from a scan result. A malformed
-- advertisement still contributes its salvaged partial (hatter's
-- scan dispatch has already logged every defect loudly, with the
-- address): a beacon with one garbled structure must not lose its
-- valid identity data.
scanResultExtData :: BleScanResult -> Maybe ByteString
scanResultExtData result = case bsrAdvertisement result of
  Left withErrors ->
    serviceDataForUuid kkmExtDataServiceUuid (partialAdvertisement withErrors)
  Right advertisement ->
    serviceDataForUuid kkmExtDataServiceUuid advertisement

-- | Refresh a listed beacon from a repeated advertisement: RSSI and
-- battery update, and the advertisement interval is measured from
-- the arrival times. Repeats from addresses that are remembered but
-- not listed (foreign devices) do nothing.
refreshBeaconSighting :: POSIXTime -> AppState -> BleScanResult -> Maybe ByteString -> IO ()
refreshBeaconSighting now appState result extData = do
  let address = unBleDeviceAddress (bsrDeviceAddress result)
  beacons <- readIORef (stateBeacons appState)
  if any (beaconHasAddress address) beacons
    then do
      modifyIORef' (stateBeacons appState) (map (\beacon ->
        if beaconHasAddress address beacon
          then refreshedBeacon now (bsrRssi result) (extData >>= kkmExtDataBattery) beacon
          else beacon))
      requestRepaint appState
    else pure ()

-- | Does this row belong to the given scan address?
beaconHasAddress :: Text -> DiscoveredBeacon -> Bool
beaconHasAddress address beacon =
  unBleDeviceAddress (targetAddress (beaconTarget beacon)) == address

-- | One beacon row after another advertisement arrived: new RSSI,
-- battery when the advertisement carried one, and the measured
-- interval updated from the arrival delta.
--
-- Decision: the interval is an exponentially smoothed average
-- (3 parts old, 1 part new) rather than the raw last delta. Android
-- delivers scan results with jitter and the radio adds a random
-- 0..10 ms advertising delay per event, so the raw delta jumps
-- around; smoothing shows a stable number that still converges
-- within a few advertisements after a period change. A delta of
-- zero milliseconds (batched duplicate delivery) is not a
-- measurement and is skipped.
refreshedBeacon :: POSIXTime -> Int -> Maybe Int -> DiscoveredBeacon -> DiscoveredBeacon
refreshedBeacon now rssi battery beacon =
  let deltaMs = round ((now - beaconLastSeenAt beacon) * 1000) :: Int
      interval = if deltaMs <= 0
        then beaconIntervalMs beacon
        else case beaconIntervalMs beacon of
          Nothing -> Just deltaMs
          Just old -> Just ((old * 3 + deltaMs) `div` 4)
  in beacon
    { beaconRssi = rssi
    , beaconBattery = case battery of
        Just percent -> Just percent
        Nothing -> beaconBattery beacon
    , beaconLastSeenAt = now
    , beaconIntervalMs = interval
    }

-- | Build the configure target for an accepted scan result.
scanResultTarget :: BeaconMac -> BleScanResult -> BeaconTarget
scanResultTarget mac result = BeaconTarget
  { targetName = bsrDeviceName result
  , targetAddress = bsrDeviceAddress result
  , targetMac = Just mac
  }

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
formatMacBytes :: ByteString -> Text
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

-- | Build the widget tree for the current page.
appView
  :: AppState
  -> Action -> Action -> Action -> Action -> Action
  -> OnChange -> OnChange -> OnChange
  -> IO Widget
appView appState
        onCheckAdapter onRequestPerms onStartScan onStopScan onConfigureAll
        onPeriodChange onThresholdChange onReportUrlChange = do
  page <- readIORef (statePage appState)
  resolvedPage <- case page of
    PermissionPage -> resolvePermissionPage appState
    ScannerPage -> pure ScannerPage
  case resolvedPage of
    PermissionPage -> permissionPageView appState onRequestPerms
    ScannerPage -> scannerPageView appState
      onCheckAdapter onStartScan onStopScan onConfigureAll
      onPeriodChange onThresholdChange onReportUrlChange

-- | On the first render, ask the platform whether both permissions
-- are already granted and skip the permission page entirely if so.
-- Probed at render time because the platform bridges are only
-- registered right before the first render runs (jni_bridge.c wires
-- them immediately before calling the view), and probed exactly once
-- so a denial does not re-run the check on every redraw.
resolvePermissionPage :: AppState -> IO AppPage
resolvePermissionPage appState = do
  alreadyProbed <- readIORef (statePermissionProbed appState)
  if alreadyProbed
    then pure PermissionPage
    else do
      writeIORef (statePermissionProbed appState) True
      bluetoothStatus <- checkPermission PermissionBluetooth
      locationStatus <- checkPermission PermissionLocation
      case (bluetoothStatus, locationStatus) of
        (PermissionGranted, PermissionGranted) -> do
          platformLog "permissions already granted, skipping the permission page"
          writeIORef (statePage appState) ScannerPage
          pure ScannerPage
        (PermissionDenied, PermissionDenied) -> pure PermissionPage
        (PermissionDenied, PermissionGranted) -> pure PermissionPage
        (PermissionGranted, PermissionDenied) -> pure PermissionPage

-- | The one-time permission page; 'continuePastPermissions' replaces
-- it with the scanner page once both permissions are granted.
permissionPageView :: AppState -> Action -> IO Widget
permissionPageView appState onRequestPerms = do
  statusLine <- readIORef (stateStatusLine appState)
  pure (column
    [ text "Finding KBeacons needs the bluetooth scan and location permissions."
    , button "Request Permissions" onRequestPerms
    , text ("Status: " <> statusLine)
    ])

-- | The scanner page: inputs, the scan toggle, and the beacon list.
scannerPageView
  :: AppState
  -> Action -> Action -> Action -> Action
  -> OnChange -> OnChange -> OnChange
  -> IO Widget
scannerPageView appState
                onCheckAdapter onStartScan onStopScan onConfigureAll
                onPeriodChange onThresholdChange onReportUrlChange = do
  beacons <- readIORef (stateBeacons appState)
  advPeriod <- readIORef (stateAdvPeriodInput appState)
  threshold <- readIORef (stateThresholdInput appState)
  reportUrl <- readIORef (stateReportUrlInput appState)
  scanning <- readIORef (stateScanning appState)
  statusLine <- readIORef (stateStatusLine appState)
  let expectedPeriod = parseAdvPeriod advPeriod
  pure (column
    [ button "Check Adapter" onCheckAdapter
    , TextInput TextInputConfig
        { tiInputType  = InputNumber
        , tiHint       = "Adv interval (ms)"
        , tiValue      = advPeriod
        , tiOnChange   = onPeriodChange
        , tiFontConfig = Nothing
        , tiTextColor  = Nothing
        , tiAutoFocus  = False
        }
    , TextInput TextInputConfig
        { tiInputType  = InputText
        , tiHint       = "RSSI threshold (dBm)"
        , tiValue      = threshold
        , tiOnChange   = onThresholdChange
        , tiFontConfig = Nothing
        , tiTextColor  = Nothing
        , tiAutoFocus  = False
        }
    , TextInput TextInputConfig
        { tiInputType  = InputText
        , tiHint       = "Report URL (optional)"
        , tiValue      = reportUrl
        , tiOnChange   = onReportUrlChange
        , tiFontConfig = Nothing
        , tiTextColor  = Nothing
        , tiAutoFocus  = False
        }
    , row
        [ if scanning
            then button "Stop Scan" onStopScan
            else button "Start Scan" onStartScan
        , button "Configure All" onConfigureAll
        ]
    , text ("Status: " <> statusLine)
    , text ("Scanning: " <> (if scanning then "yes" else "no")
        <> " | " <> pack (show (length beacons)) <> " device(s) found")
    , beaconTableHeader
    , scrollColumn (map (beaconTableRow expectedPeriod)
        (sortBy (comparing (Down . beaconRssi)) beacons))
    ])

-- | The table's column headers.
beaconTableHeader :: Widget
beaconTableHeader = row
  [ text "serial"
  , text " | rssi"
  , text " | battery"
  , text " | rate (ms)"
  , text " | status"
  ]

-- | How a beacon's measured advertisement interval relates to the
-- expected interval input.
data RateVerdict
  = RateUnknown
    -- ^ No measurement yet, or no valid expected interval to compare
    -- against.
  | RateMatching
  | RateDeviating
  deriving (Show, Eq)

-- | Compare the measured interval with the expected one.
--
-- Decision: matching means within 25% of the expected interval. BLE
-- adds a random 0..10 ms delay to every advertising event and the
-- platform delivers results with its own jitter, so exact matching
-- would flag healthy beacons; a beacon actually configured to a
-- different period (the closest firmware steps are well over 25%
-- apart) still lands far outside the band.
rateVerdict :: Either Text AdvPeriodMs -> Maybe Int -> RateVerdict
rateVerdict expected measured =
  case (expected, measured) of
    (Left _, Nothing) -> RateUnknown
    (Left _, Just _) -> RateUnknown
    (Right _, Nothing) -> RateUnknown
    (Right expectedPeriod, Just measuredMs) ->
      if abs (measuredMs - unAdvPeriodMs expectedPeriod) * 4
           <= unAdvPeriodMs expectedPeriod
        then RateMatching
        else RateDeviating

-- | Row text color for a rate verdict: green when the beacon
-- advertises at the expected rate, red when it deviates, unstyled
-- while unknown.
rateColor :: RateVerdict -> Maybe Color
rateColor verdict = case verdict of
  RateUnknown -> Nothing
  RateMatching -> Just (Color 0x2E 0x7D 0x32 0xFF)
  RateDeviating -> Just (Color 0xC6 0x28 0x28 0xFF)

-- | One table row per discovered beacon: serial, RSSI, battery, the
-- device's rate and the status, each cell its own node (the emulator
-- test exact-matches the deterministic cells) and colored by the
-- rate verdict.
beaconTableRow :: Either Text AdvPeriodMs -> DiscoveredBeacon -> Widget
beaconTableRow expectedPeriod beacon =
  let color = rateColor (rateVerdict expectedPeriod (beaconIntervalMs beacon))
      batteryCell = case beaconBattery beacon of
        Just percent -> pack (show percent)
        Nothing -> "?"
      statusText = case beaconStatus beacon of
        StatusFound -> "not yet configured"
        StatusConfiguring -> "configuring..."
        StatusConfigured _ -> "configured"
        StatusFailed failure -> "failed: " <> failure
      reportText = case beaconReportNote beacon of
        Just note -> " | " <> note
        Nothing -> ""
  in row
    [ rowText color (beaconSerial beacon)
    , rowText color (" | " <> pack (show (beaconRssi beacon)))
    , rowText color (" | " <> batteryCell)
    , rowText color (" | " <> beaconRateCell beacon)
    , rowText color (" | " <> statusText <> reportText)
    ]

-- | A beacon's serial number: the hex digits of its MAC's low three
-- bytes, the same digits factory names carry after their "KBPro-"
-- prefix, so renamed beacons show a stable serial too. Falls back to
-- the name's dash-suffix when no MAC is known.
beaconSerial :: DiscoveredBeacon -> Text
beaconSerial beacon = case targetMac (beaconTarget beacon) of
  Just mac -> Text.concat
    (map formatMacByte (ByteString.unpack (ByteString.drop 3 (unBeaconMac mac))))
  Nothing -> Text.takeWhileEnd (/= '-') (targetName (beaconTarget beacon))

-- | The rate cell: the exact period once this beacon was configured,
-- the measured estimate (tilde) while only observed, "?" until a
-- second advertisement gives a measurement.
beaconRateCell :: DiscoveredBeacon -> Text
beaconRateCell beacon = case beaconStatus beacon of
  StatusConfigured success ->
    pack (show (unAdvPeriodMs (successAppliedPeriod success)))
  StatusFound -> measuredRateCell (beaconIntervalMs beacon)
  StatusConfiguring -> measuredRateCell (beaconIntervalMs beacon)
  StatusFailed _ -> measuredRateCell (beaconIntervalMs beacon)

-- | The measured half of 'beaconRateCell'.
measuredRateCell :: Maybe Int -> Text
measuredRateCell interval = case interval of
  Just intervalMs -> "~" <> pack (show intervalMs)
  Nothing -> "?"

-- | A row text fragment carrying the rate color when there is one.
-- Text color lives on the text config itself (hatter #242), so it
-- can only ever land on glyph-bearing nodes.
rowText :: Maybe Color -> Text -> Widget
rowText color content = case color of
  Nothing -> text content
  Just chosen -> coloredText chosen content
