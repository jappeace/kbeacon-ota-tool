{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE OverloadedStrings #-}
-- | Sequential configuration of scanned KBeacons over Hatter.Ble.
--
-- For each beacon in turn: connect, negotiate the MTU, discover
-- services, subscribe to the FEA2 notify characteristic, run the MD5
-- auth handshake, read the current configuration (battery percent and
-- slot layout), write the new advertisement period, and disconnect.
-- All pure protocol logic lives in "KBeacon.Protocol"; this module is
-- only the event plumbing between hatter's callbacks and that logic.
--
-- Decision: a callback-driven state machine around one IORef instead
-- of threads. Hatter apps run on the non-threaded GHC RTS on Android
-- (see hatter's RedrawDemoMain: forkIO/threadDelay cannot be
-- scheduled between JNI callbacks), so blocking or timing out in
-- Haskell is not available. Every state transition happens inside a
-- platform callback. Stall protection comes from the platform:
-- connect attempts and GATT operations fail through their callbacks,
-- and an unresponsive-but-connected beacon eventually drops the link,
-- which we treat as failure and move on.
--
-- Decision: every callback registered for a beacon captures that
-- beacon's serial number and is ignored when the serial no longer
-- matches the active beacon. The platform can deliver late events
-- (a trailing connection-closed after a failed connect, a GATT
-- completion racing a link drop); without the serial check those
-- would be misattributed to the next beacon in the queue. The
-- alternative, deregistering callbacks, is not available: hatter only
-- replaces callbacks on the next registration.
module KBeacon.Configure
  ( BeaconTarget(..)
  , BeaconOutcome(..)
  , BeaconSuccess(..)
  , startConfigureSession
  ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock.POSIX (getPOSIXTime)
import Hatter.Ble
  ( BleCharacteristicUuid(..)
  , BleCharacteristicValue(..)
  , BleConnectionEvent(..)
  , BleDeviceAddress(..)
  , BleDiscoveredCharacteristic(..)
  , BleGattError(..)
  , BleMtu(..)
  , BleServiceUuid(..)
  , BleState(..)
  , BleWriteMode(..)
  , connectBleDevice
  , disconnectBleDevice
  , discoverBleServices
  , normalizeBleServiceUuid
  , requestBleMtu
  , subscribeBleCharacteristic
  , writeBleCharacteristic
  )
import KBeacon.Protocol
  ( AdvPeriodMs
  , AppRandom(..)
  , AuthEvent(..)
  , AuthVariant(..)
  , BeaconMac
  , BeaconNotification(..)
  , BeaconPassword
  , FrameBudget
  , JsonAck(..)
  , ParaInfo(..)
  , ReportAssembly
  , ReportFragment
  , appendReportFragment
  , appRandomFromPicoseconds
  , ackCauseCommandReceived
  , ackCauseExpectNext
  , ackCauseReportComplete
  , ackCauseReportIncomplete
  , ackCauseSuccess
  , authPhase1Request
  , authPhase2Request
  , defaultFrameBudget
  , emptyReportAssembly
  , encodeJsonRequestFrames
  , expectedDeviceProof
  , getParaRequestJson
  , kbConfigServiceUuidText
  , kbNotifyCharacteristicUuidText
  , kbWriteCharacteristicUuidText
  , negotiatedFrameBudget
  , parseBeaconNotification
  , parseParaResponse
  , paraBatteryPercent
  , reportAckFrame
  , setAdvPeriodJson
  , slotToConfigure
  , unReportAssembly
  , xorFoldDigest
  )

-- | The KBeacon config service as a hatter UUID.
kbConfigService :: BleServiceUuid
kbConfigService = BleServiceUuid kbConfigServiceUuidText

-- | The FEA1 write characteristic as a hatter UUID.
kbWriteCharacteristic :: BleCharacteristicUuid
kbWriteCharacteristic = BleCharacteristicUuid kbWriteCharacteristicUuidText

-- | The FEA2 notify characteristic as a hatter UUID.
kbNotifyCharacteristic :: BleCharacteristicUuid
kbNotifyCharacteristic = BleCharacteristicUuid kbNotifyCharacteristicUuidText

-- | One beacon selected for configuration.
data BeaconTarget = BeaconTarget
  { targetName :: Text
  , targetAddress :: BleDeviceAddress
  , targetMac :: Maybe BeaconMac
    -- ^ Derived from the address (Android) or the name suffix (iOS);
    -- 'Nothing' when neither works, in which case auth is impossible.
  } deriving (Show, Eq)

-- | Result for one beacon.
data BeaconOutcome = BeaconOutcome
  { outcomeTarget :: BeaconTarget
  , outcomeResult :: Either Text BeaconSuccess
  } deriving (Show, Eq)

-- | What a successful configuration learned.
data BeaconSuccess = BeaconSuccess
  { successAppliedPeriod :: AdvPeriodMs
  , successBatteryPercent :: Maybe Int
  } deriving (Show, Eq)

-- | Where the active beacon is in the protocol. The happy path runs
-- top to bottom:
--
-- @
-- Connecting -> RequestingMtu -> Discovering -> Subscribing
--   -> AwaitingChallenge -> AwaitingAuthResult
--   -> AwaitingParaResponse [-> CollectingParaReports]
--   -> AwaitingCfgAck -> Disconnecting -> (next beacon)
-- @
--
-- CollectingParaReports only happens when the beacon sends its config
-- as fragmented report frames instead of piggybacked on the ack. Any
-- failure jumps straight to Disconnecting with 'activeFailure' set.
data SessionPhase
  = PhaseConnecting
  | PhaseRequestingMtu
  | PhaseDiscovering
  | PhaseSubscribing
  | PhaseAwaitingChallenge
  | PhaseAwaitingAuthResult
  | PhaseAwaitingParaResponse
  | PhaseCollectingParaReports
  | PhaseAwaitingCfgAck
  | PhaseDisconnecting
  deriving (Show, Eq)

-- | Identifies which beacon attempt a callback was registered for.
newtype BeaconSerial = BeaconSerial Int
  deriving (Show, Eq)

-- | Everything mutable about the session.
data SessionState = SessionState
  { sessionQueue :: [BeaconTarget]
  , sessionActive :: Maybe ActiveBeacon
  , sessionNextSerial :: Int
  }

-- | State for the beacon currently being configured.
data ActiveBeacon = ActiveBeacon
  { activeTarget :: BeaconTarget
  , activeSerial :: BeaconSerial
  , activeMac :: BeaconMac
  , activePhase :: SessionPhase
  , activeAppRandom :: AppRandom
  , activeAuthVariant :: AuthVariant
  , activeLocalMtu :: Maybe Int
    -- ^ ATT MTU the local stack granted, when negotiation succeeded.
  , activeBudget :: FrameBudget
  , activePendingFrames :: [ByteString]
    -- ^ Fragments still to send when the beacon acks "expect next".
  , activeWriteQueue :: [ByteString]
    -- ^ Frames waiting for the previous GATT write to complete
    -- (hatter allows one outstanding GATT operation).
  , activeWriteInFlight :: Bool
  , activeAssembly :: ReportAssembly
  , activePara :: Maybe ParaInfo
  , activeFailure :: Maybe Text
    -- ^ Set before a failure disconnect so the close event knows the
    -- outcome.
  }

-- | Immutable session context shared by every callback.
data SessionContext = SessionContext
  { contextBleState :: BleState
  , contextPeriod :: AdvPeriodMs
  , contextPassword :: BeaconPassword
  , contextLog :: Text -> IO ()
  , contextOnOutcome :: BeaconOutcome -> IO ()
  , contextOnFinished :: IO ()
  , contextState :: IORef SessionState
  }

-- | Configure every target in order and report progress through the
-- callbacks. Runs entirely inside hatter's callback loop; the final
-- callback fires when the queue is exhausted.
startConfigureSession
  :: BleState
  -> AdvPeriodMs
  -> BeaconPassword
  -> [BeaconTarget]
  -> (Text -> IO ())
  -> (BeaconOutcome -> IO ())
  -> IO ()
  -> IO ()
startConfigureSession bleState period password targets logLine onOutcome onFinished = do
  stateRef <- newIORef SessionState
    { sessionQueue = targets
    , sessionActive = Nothing
    , sessionNextSerial = 0
    }
  let context = SessionContext
        { contextBleState = bleState
        , contextPeriod = period
        , contextPassword = password
        , contextLog = logLine
        , contextOnOutcome = onOutcome
        , contextOnFinished = onFinished
        , contextState = stateRef
        }
  advanceQueue context

-- | Start on the next queued beacon, or finish the session.
advanceQueue :: SessionContext -> IO ()
advanceQueue context = do
  state <- readIORef (contextState context)
  case sessionQueue state of
    [] -> do
      writeIORef (contextState context) state
        { sessionQueue = [], sessionActive = Nothing }
      contextOnFinished context
    (target : remaining) ->
      case targetMac target of
        Nothing -> do
          writeIORef (contextState context)
            state { sessionQueue = remaining, sessionActive = Nothing }
          contextOnOutcome context BeaconOutcome
            { outcomeTarget = target
            , outcomeResult = Left "cannot derive the MAC needed for authentication (rename the beacon back to its factory name, or run from Android)"
            }
          advanceQueue context
        Just mac -> do
          appRandom <- freshAppRandom
          let serial = BeaconSerial (sessionNextSerial state)
          writeIORef (contextState context) SessionState
            { sessionQueue = remaining
            , sessionNextSerial = sessionNextSerial state + 1
            , sessionActive = Just ActiveBeacon
                { activeTarget = target
                , activeSerial = serial
                , activeMac = mac
                , activePhase = PhaseConnecting
                , activeAppRandom = appRandom
                , activeAuthVariant = AuthFullDigest
                , activeLocalMtu = Nothing
                , activeBudget = defaultFrameBudget
                , activePendingFrames = []
                , activeWriteQueue = []
                , activeWriteInFlight = False
                , activeAssembly = emptyReportAssembly
                , activePara = Nothing
                , activeFailure = Nothing
                }
            }
          contextLog context
            ("configuring " <> targetName target <> " ("
              <> unBleDeviceAddress (targetAddress target) <> ")")
          connectBleDevice (contextBleState context) (targetAddress target)
            (onConnectionEvent context serial)

-- | Four challenge bytes derived from the wall clock (see
-- 'appRandomFromPicoseconds' for why that is enough randomness).
freshAppRandom :: IO AppRandom
freshAppRandom = do
  now <- getPOSIXTime
  pure (appRandomFromPicoseconds (truncate (now * 1e12)))

-- | Current UTC time in seconds for auth phase 1's clock sync.
currentUtcSeconds :: IO Integer
currentUtcSeconds = do
  now <- getPOSIXTime
  pure (truncate now)

-- | Run an update against the active beacon, but only when the event
-- belongs to it: late platform events from a previous beacon (or
-- events after a failure cleared the slot) are logged and dropped.
withActiveBeacon :: SessionContext -> BeaconSerial -> Text -> (ActiveBeacon -> IO ()) -> IO ()
withActiveBeacon context serial eventLabel handler = do
  state <- readIORef (contextState context)
  case sessionActive state of
    Just active ->
      if activeSerial active == serial
        then handler active
        else contextLog context
          ("ignoring " <> eventLabel <> " event from a previous beacon attempt")
    Nothing -> contextLog context
      ("ignoring late " <> eventLabel <> " event: no active beacon")

-- | Store a modified active beacon.
storeActiveBeacon :: SessionContext -> ActiveBeacon -> IO ()
storeActiveBeacon context active = do
  state <- readIORef (contextState context)
  writeIORef (contextState context) state { sessionActive = Just active }

-- | Fail the active beacon: record the reason and disconnect; the
-- close event delivers the outcome and advances the queue.
failActiveBeacon :: SessionContext -> ActiveBeacon -> Text -> IO ()
failActiveBeacon context active reason = do
  contextLog context (targetName (activeTarget active) <> " failed: " <> reason)
  storeActiveBeacon context active
    { activeFailure = Just reason
    , activePhase = PhaseDisconnecting
    }
  disconnectBleDevice (contextBleState context)

-- | Deliver the active beacon's outcome and move to the next target.
finishActiveBeacon :: SessionContext -> ActiveBeacon -> Either Text BeaconSuccess -> IO ()
finishActiveBeacon context active result = do
  state <- readIORef (contextState context)
  writeIORef (contextState context) state { sessionActive = Nothing }
  contextOnOutcome context BeaconOutcome
    { outcomeTarget = activeTarget active
    , outcomeResult = result
    }
  advanceQueue context

-- | Connection events for the beacon we asked hatter to connect to.
onConnectionEvent :: SessionContext -> BeaconSerial -> BleConnectionEvent -> IO ()
onConnectionEvent context serial event =
  withActiveBeacon context serial "connection" $ \active ->
    case event of
      BleConnectionEstablished ->
        if activePhase active == PhaseConnecting
          then do
            storeActiveBeacon context active { activePhase = PhaseRequestingMtu }
            -- 251 is what KKM's library requests; the granted value
            -- caps the frame budget together with the beacon's limit.
            requestBleMtu (contextBleState context) (BleMtu 251)
              (onMtuResult context serial)
          else contextLog context "ignoring duplicate connection-established event"
      BleConnectionClosed -> onConnectionEnded context active "connection closed"
      BleConnectionFailed -> onConnectionEnded context active "connection failed"

-- | A closed or failed link ends the active beacon: expected when we
-- are disconnecting (outcome already decided), a failure anywhere
-- else.
onConnectionEnded :: SessionContext -> ActiveBeacon -> Text -> IO ()
onConnectionEnded context active reason = do
  clearOrphanedGattOperation context
  case activePhase active of
    PhaseDisconnecting ->
      case activeFailure active of
        Just failure -> finishActiveBeacon context active (Left failure)
        Nothing -> finishActiveBeacon context active (Right BeaconSuccess
          { successAppliedPeriod = contextPeriod context
          , successBatteryPercent = activePara active >>= paraBatteryPercent
          })
    PhaseConnecting -> finishActiveBeacon context active
      (Left ("could not connect: " <> reason))
    PhaseRequestingMtu -> finishActiveBeacon context active (Left reason)
    PhaseDiscovering -> finishActiveBeacon context active (Left reason)
    PhaseSubscribing -> finishActiveBeacon context active (Left reason)
    PhaseAwaitingChallenge -> finishActiveBeacon context active (Left reason)
    PhaseAwaitingAuthResult -> finishActiveBeacon context active
      (Left (reason <> " during authentication (wrong password?)"))
    PhaseAwaitingParaResponse -> finishActiveBeacon context active (Left reason)
    PhaseCollectingParaReports -> finishActiveBeacon context active (Left reason)
    PhaseAwaitingCfgAck -> finishActiveBeacon context active (Left reason)

-- | Clear hatter's single pending-GATT-operation slot when the link
-- ends. The platform never completes an operation that was in flight
-- when the connection dropped, so without this the stale entry makes
-- every operation on the NEXT connection fail with BleGattBusy.
--
-- Decision: the slot is cleared without invoking the orphaned
-- operation's callback. The callback belongs to the beacon that is
-- being finished right now; delivering a late failure into it after
-- the queue advances would be misrouted (and our write-completion
-- handler would misread it as the next beacon's write failing).
clearOrphanedGattOperation :: SessionContext -> IO ()
clearOrphanedGattOperation context = do
  let pendingRef = blesGattPending (contextBleState context)
  pending <- readIORef pendingRef
  case pending of
    Nothing -> pure ()
    Just _ -> do
      contextLog context "clearing the GATT operation orphaned by the ended connection"
      writeIORef pendingRef Nothing

-- | MTU negotiation result. A failure is not fatal: the default
-- 23-byte budget still works, the frames just get smaller.
onMtuResult :: SessionContext -> BeaconSerial -> Either BleGattError BleMtu -> IO ()
onMtuResult context serial result =
  withActiveBeacon context serial "mtu" $ \active -> do
    grantedMtu <- case result of
      Left gattError -> do
        contextLog context ("MTU request failed, continuing with default: "
          <> Text.pack (show gattError))
        pure Nothing
      Right granted -> do
        contextLog context ("MTU granted: " <> Text.pack (show (unBleMtu granted)))
        pure (Just (unBleMtu granted))
    storeActiveBeacon context active
      { activePhase = PhaseDiscovering
      , activeLocalMtu = grantedMtu
      }
    discoverBleServices (contextBleState context) (onDiscoveryResult context serial)

-- | Service discovery result: the beacon must expose the KBeacon
-- config service with its write and notify characteristics.
onDiscoveryResult
  :: SessionContext
  -> BeaconSerial
  -> Either BleGattError [BleDiscoveredCharacteristic]
  -> IO ()
onDiscoveryResult context serial result =
  withActiveBeacon context serial "discovery" $ \active ->
    case result of
      Left gattError ->
        failActiveBeacon context active
          ("service discovery failed: " <> Text.pack (show gattError))
      Right discovered ->
        if hasKBeaconConfigCharacteristics discovered
          then do
            storeActiveBeacon context active { activePhase = PhaseSubscribing }
            subscribeBleCharacteristic (contextBleState context)
              kbConfigService kbNotifyCharacteristic
              (onBeaconNotification context serial)
              (onSubscribed context serial)
          else failActiveBeacon context active
            "device does not expose the KBeacon config service (FEA0 with FEA1/FEA2)"

-- | Whether a discovered characteristic sits in the KBeacon config
-- service, comparing case-normalized UUIDs (Android reports
-- lowercase, iOS uppercase).
inKBeaconConfigService :: BleDiscoveredCharacteristic -> Bool
inKBeaconConfigService entry =
  normalizeBleServiceUuid (bdcService entry)
    == normalizeBleServiceUuid kbConfigService

-- | Check for FEA1 and FEA2 under FEA0.
hasKBeaconConfigCharacteristics :: [BleDiscoveredCharacteristic] -> Bool
hasKBeaconConfigCharacteristics discovered =
  let configEntries = filter inKBeaconConfigService discovered
      lowered = map (Text.toLower . unBleCharacteristicUuid . bdcCharacteristic) configEntries
      writePresent = elem (Text.toLower kbWriteCharacteristicUuidText) lowered
      notifyPresent = elem (Text.toLower kbNotifyCharacteristicUuidText) lowered
  in writePresent && notifyPresent

-- | Subscription confirmed: send auth phase 1.
onSubscribed :: SessionContext -> BeaconSerial -> Either BleGattError () -> IO ()
onSubscribed context serial result =
  withActiveBeacon context serial "subscribe" $ \active ->
    case result of
      Left gattError ->
        failActiveBeacon context active
          ("subscribing to notifications failed: " <> Text.pack (show gattError))
      Right () -> do
        utcSeconds <- currentUtcSeconds
        storeActiveBeacon context active { activePhase = PhaseAwaitingChallenge }
        enqueueFrame context serial (authPhase1Request (activeAppRandom active) utcSeconds)

-- | Queue a frame for the FEA1 write characteristic. Hatter permits
-- one outstanding GATT operation, so writes issue strictly one at a
-- time; anything arriving while a write is in flight waits in the
-- queue.
enqueueFrame :: SessionContext -> BeaconSerial -> ByteString -> IO ()
enqueueFrame context serial frame =
  withActiveBeacon context serial "write" $ \active ->
    if activeWriteInFlight active
      then storeActiveBeacon context active
        { activeWriteQueue = activeWriteQueue active ++ [frame] }
      else do
        storeActiveBeacon context active { activeWriteInFlight = True }
        writeFrame context serial frame

-- | Issue one write to FEA1 (without response, like KKM's libraries).
writeFrame :: SessionContext -> BeaconSerial -> ByteString -> IO ()
writeFrame context serial frame =
  writeBleCharacteristic (contextBleState context)
    kbConfigService kbWriteCharacteristic
    BleWriteWithoutResponse (BleCharacteristicValue frame)
    (onFrameWritten context serial)

-- | Write completion: send the next queued frame, if any. A write
-- error is fatal for the active beacon.
onFrameWritten :: SessionContext -> BeaconSerial -> Either BleGattError () -> IO ()
onFrameWritten context serial result =
  withActiveBeacon context serial "write-completion" $ \active ->
    case result of
      Left gattError ->
        failActiveBeacon context active
          ("characteristic write failed: " <> Text.pack (show gattError))
      Right () ->
        case activeWriteQueue active of
          [] -> storeActiveBeacon context active { activeWriteInFlight = False }
          (next : remaining) -> do
            storeActiveBeacon context active { activeWriteQueue = remaining }
            writeFrame context serial next

-- | Every FEA2 notification lands here and is routed by its decoded
-- type and the current phase.
onBeaconNotification :: SessionContext -> BeaconSerial -> BleCharacteristicValue -> IO ()
onBeaconNotification context serial (BleCharacteristicValue frame) =
  withActiveBeacon context serial "notification" $ \active ->
    case parseBeaconNotification frame of
      Left parseError ->
        failActiveBeacon context active ("unparseable notification: " <> parseError)
      Right (AuthNotification authEvent) -> handleAuthEvent context active authEvent
      Right (AckNotification ack) -> handleJsonAck context active ack
      Right (ReportNotification fragment) -> handleReportFragment context active fragment
      Right (UnsupportedNotification dataType) ->
        contextLog context ("ignoring notification with data type "
          <> Text.pack (show dataType))

-- | Auth channel handling.
handleAuthEvent :: SessionContext -> ActiveBeacon -> AuthEvent -> IO ()
handleAuthEvent context active = \case
  AuthChallenge variant deviceRandom deviceProof ->
    if activePhase active /= PhaseAwaitingChallenge
      then contextLog context "ignoring auth challenge outside the challenge phase"
      else
        let expected = expectedDeviceProof (activeMac active)
              (unAppRandom (activeAppRandom active)) (contextPassword context)
            expectedForVariant = case variant of
              AuthFullDigest -> expected
              AuthShortDigest -> xorFoldDigest expected
        in if deviceProof /= expectedForVariant
          then failActiveBeacon context active
            "beacon's auth proof does not match (wrong password, or MAC derived from the name is wrong)"
          else do
            storeActiveBeacon context active
              { activePhase = PhaseAwaitingAuthResult
              , activeAuthVariant = variant
              }
            enqueueFrame context (activeSerial active)
              (authPhase2Request (activeMac active)
                deviceRandom (contextPassword context) variant)
  AuthSucceeded reportedMtu ->
    if activePhase active /= PhaseAwaitingAuthResult
      then contextLog context "ignoring auth success outside the auth phase"
      else do
        contextLog context (targetName (activeTarget active)
          <> " authenticated (reported MTU " <> Text.pack (show reportedMtu) <> ")")
        sendJsonRequest context active
          { activePhase = PhaseAwaitingParaResponse
          , activeBudget = negotiatedFrameBudget (activeLocalMtu active) reportedMtu
          , activeAssembly = emptyReportAssembly
          }
          getParaRequestJson
  AuthRejected ->
    failActiveBeacon context active "beacon rejected authentication (wrong password)"

-- | Fragment a JSON message for the current budget, queue the first
-- frame, and hold the rest for "expect next" acks.
sendJsonRequest :: SessionContext -> ActiveBeacon -> ByteString -> IO ()
sendJsonRequest context active message =
  case encodeJsonRequestFrames (activeBudget active) message of
    [] -> failActiveBeacon context active "frame encoder produced no frames"
    (firstFrame : laterFrames) -> do
      storeActiveBeacon context active { activePendingFrames = laterFrames }
      enqueueFrame context (activeSerial active) firstFrame

-- | Ack handling for the JSON channel.
handleJsonAck :: SessionContext -> ActiveBeacon -> JsonAck -> IO ()
handleJsonAck context active ack = if
  | jsonAckCause ack == ackCauseExpectNext ->
      case activePendingFrames active of
        [] -> failActiveBeacon context active
          "beacon asked for a next fragment but none is pending"
        (next : remaining) -> do
          storeActiveBeacon context active { activePendingFrames = remaining }
          enqueueFrame context (activeSerial active) next
  | jsonAckCause ack == ackCauseCommandReceived ->
      if activePhase active == PhaseAwaitingParaResponse
        then storeActiveBeacon context active
          { activePhase = PhaseCollectingParaReports
          , activeAssembly = emptyReportAssembly
          }
        else contextLog context "ignoring command-received ack outside a read"
  | jsonAckCause ack == ackCauseReportComplete
      || jsonAckCause ack == ackCauseReportIncomplete ->
      -- Progress markers for long transfers: informational, the real
      -- data arrives through report frames.
      contextLog context ("beacon transfer progress ack, cause "
        <> Text.pack (show (jsonAckCause ack)))
  | jsonAckCause ack == ackCauseSuccess ->
      case activePhase active of
        PhaseAwaitingParaResponse ->
          -- Short responses ride piggyback on the success ack.
          handleParaResponse context active (jsonAckPayload ack)
        PhaseAwaitingCfgAck -> do
          contextLog context (targetName (activeTarget active)
            <> " committed the new advertisement period")
          storeActiveBeacon context active { activePhase = PhaseDisconnecting }
          disconnectBleDevice (contextBleState context)
        PhaseConnecting -> ignoreSuccessAck context
        PhaseRequestingMtu -> ignoreSuccessAck context
        PhaseDiscovering -> ignoreSuccessAck context
        PhaseSubscribing -> ignoreSuccessAck context
        PhaseAwaitingChallenge -> ignoreSuccessAck context
        PhaseAwaitingAuthResult -> ignoreSuccessAck context
        PhaseCollectingParaReports -> ignoreSuccessAck context
        PhaseDisconnecting -> ignoreSuccessAck context
  | otherwise ->
      failActiveBeacon context active
        ("beacon reported error code " <> Text.pack (show (jsonAckCause ack)))

-- | Success acks outside a request/response exchange carry no work.
ignoreSuccessAck :: SessionContext -> IO ()
ignoreSuccessAck context =
  contextLog context "ignoring success ack outside a pending request"

-- | Report fragments: reassemble the long getPara response, acking
-- every fragment. The completion handler re-reads the session state:
-- 'enqueueFrame' mutates the write queue flags, so the copy taken at
-- dispatch time is stale by then.
handleReportFragment :: SessionContext -> ActiveBeacon -> ReportFragment -> IO ()
handleReportFragment context active fragment =
  if activePhase active /= PhaseCollectingParaReports
    then contextLog context "ignoring report fragment outside a read"
    else case appendReportFragment (activeAssembly active) fragment of
      Left assemblyError -> failActiveBeacon context active assemblyError
      Right (grown, complete) -> do
        let received = BS.length (unReportAssembly grown)
            serial = activeSerial active
        storeActiveBeacon context active { activeAssembly = grown }
        enqueueFrame context serial (reportAckFrame received)
        if complete
          then withActiveBeacon context serial "report-completion" $ \fresh ->
            handleParaResponse context fresh (unReportAssembly grown)
          else pure ()

-- | A complete getPara response: parse it, pick the slot, and write
-- the new period.
handleParaResponse :: SessionContext -> ActiveBeacon -> ByteString -> IO ()
handleParaResponse context active raw =
  case parseParaResponse raw of
    Left parseError ->
      failActiveBeacon context active ("could not parse beacon config: " <> parseError)
    Right para ->
      case slotToConfigure para of
        Left slotError -> failActiveBeacon context active slotError
        Right slot -> do
          contextLog context (targetName (activeTarget active)
            <> " battery: "
            <> maybe "unknown" (\percent -> Text.pack (show percent) <> "%")
                (paraBatteryPercent para))
          sendJsonRequest context active
            { activePara = Just para
            , activePhase = PhaseAwaitingCfgAck
            }
            (setAdvPeriodJson slot (contextPeriod context))
