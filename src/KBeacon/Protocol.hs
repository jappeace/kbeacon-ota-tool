{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE OverloadedStrings #-}
-- | Pure implementation of the KBeacon Pro (KKM) GATT configuration
-- protocol: the MD5 auth handshake, the frame codec on the FEA1/FEA2
-- characteristic pair, and the JSON config messages.
--
-- Reverse engineered from KKM's official Android library
-- (kkmhogen/android_kbeaconlib2: KBeacon.java, KBAuthHandler.java,
-- KBUtility.java, KBCfgHandler.java) and cross-checked against the
-- iOS port (kkmhogen/kbeaconlib2). All multi-byte integers in the
-- framing are big-endian. There are no checksums; sequence numbers
-- are plain byte offsets.
--
-- This module is deliberately hatter-free (plain 'ByteString' in,
-- plain 'ByteString' out) so every step of the wire protocol is unit
-- testable; "KBeacon.Configure" wires it to Hatter.Ble.
module KBeacon.Protocol
  ( -- * UUID constants
    kbConfigServiceUuidText
  , kbWriteCharacteristicUuidText
  , kbNotifyCharacteristicUuidText
    -- * Device identity
  , BeaconMac(..)
  , macFromAddress
  , macFromName
  , ScanIdentity(..)
  , identifyScanResult
  , kkmExtDataServiceUuidText
  , kkmExtDataBattery
  , kkmExtDataMac
    -- * Auth handshake
  , BeaconPassword(..)
  , defaultBeaconPassword
  , AppRandom(..)
  , AuthVariant(..)
  , appRandomFromPicoseconds
  , authPhase1Request
  , expectedDeviceProof
  , authPhase2Request
  , xorFoldDigest
    -- * Frame codec
  , FrameBudget(..)
  , defaultFrameBudget
  , frameBudgetFromAttMtu
  , minFrameBudget
  , negotiatedFrameBudget
  , encodeJsonRequestFrames
  , BeaconNotification(..)
  , AuthEvent(..)
  , JsonAck(..)
  , ackCauseSuccess
  , ackCauseExpectNext
  , ackCauseCommandReceived
  , ackCauseReportComplete
  , ackCauseReportIncomplete
  , ReportFragment(..)
  , FragmentPosition(..)
  , parseBeaconNotification
  , ReportAssembly(..)
  , emptyReportAssembly
  , appendReportFragment
  , reportAckFrame
    -- * Config messages
  , getParaRequestJson
  , setAdvPeriodJson
  , AdvSlot(..)
  , ParaInfo(..)
  , parseParaResponse
  , slotToConfigure
  , AdvPeriodMs(..)
  , validateAdvPeriod
  ) where

import Crypto.Hash.MD5 qualified as MD5
import Data.Bits (shiftL, shiftR, xor, (.&.), (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Char (isHexDigit)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word8)
import KBeacon.Json
  ( JsonValue(..)
  , hexDigitValue
  , jsonArrayItems
  , jsonInt
  , jsonNumberFromInt
  , lookupField
  , parseJson
  , renderJson
  )
import Unwitch.Convert.Int qualified as Int
import Unwitch.Convert.Integer qualified as Integer
import Unwitch.Convert.Word8 qualified as Word8

-- | KBeacon configuration GATT service (present in the GATT table,
-- never advertised).
kbConfigServiceUuidText :: Text
kbConfigServiceUuidText = "0000FEA0-0000-1000-8000-00805F9B34FB"

-- | Write characteristic: every app-to-beacon frame goes here,
-- written without response.
kbWriteCharacteristicUuidText :: Text
kbWriteCharacteristicUuidText = "0000FEA1-0000-1000-8000-00805F9B34FB"

-- | Notify characteristic: every beacon-to-app frame (auth responses,
-- acks, config data) arrives here. Subscribe before authenticating.
kbNotifyCharacteristicUuidText :: Text
kbNotifyCharacteristicUuidText = "0000FEA2-0000-1000-8000-00805F9B34FB"

-- | The 6 bytes of a beacon's Bluetooth MAC address, most significant
-- byte first (the order it is printed in "AA:BB:CC:DD:EE:FF").
newtype BeaconMac = BeaconMac { unBeaconMac :: ByteString }
  deriving (Show, Eq)

-- | KKM's Bluetooth OUI: every KBeacon MAC starts with BC:57:29.
-- The iOS KKM library reconstructs full MACs from this prefix plus
-- the 3 low bytes found in the advertisement
-- (KBAdvPacketHandler.swift, "BC:57:29:%02X:%02X:%02X").
kkmOuiPrefix :: ByteString
kkmOuiPrefix = BS.pack [0xBC, 0x57, 0x29]

-- | Parse a printed MAC address ("AA:BB:CC:DD:EE:FF", case
-- insensitive). This is what Android's scan results deliver in the
-- device address field.
macFromAddress :: Text -> Maybe BeaconMac
macFromAddress address =
  let parts = Text.splitOn ":" address
  in if length parts == 6
    then fmap (BeaconMac . BS.pack) (traverse parseHexByte parts)
    else Nothing

-- | Parse one two-digit hex byte. The narrowing always succeeds
-- (two hex digits sum to at most 255); routing it through the same
-- Maybe keeps the function total without an impossible error branch.
parseHexByte :: Text -> Maybe Word8
parseHexByte part =
  if Text.length part == 2 && Text.all isHexDigit part
    then Int.toWord8 (Text.foldl' (\total c -> total * 16 + hexDigitValue c) 0 part)
    else Nothing

-- | Recover a KBeacon's MAC from its advertised name. Factory-named
-- devices advertise "KBPro-" (or another prefix) followed by the six
-- hex digits of the MAC's low three bytes; combined with KKM's fixed
-- OUI that reconstructs the full MAC.
--
-- Decision: needed because iOS never exposes MAC addresses to
-- applications (CoreBluetooth hands out per-phone UUIDs) while the
-- auth MD5 is keyed on the MAC. The primary iOS path is
-- 'kkmExtDataMac' (the MAC bytes inside the 0x2080 service data,
-- which is what KKM's own iOS library parses); the name suffix
-- covers factory-named beacons whose frame carried no service data.
macFromName :: Text -> Maybe BeaconMac
macFromName name =
  let suffix = Text.takeEnd 6 name
  in if Text.length suffix == 6 && Text.all isHexDigit suffix
    then case traverse parseHexByte (Text.chunksOf 2 suffix) of
      Just lowBytes -> Just (BeaconMac (kkmOuiPrefix <> BS.pack lowBytes))
      Nothing -> Nothing
    else Nothing

-- | What a scan result tells us about the advertising device.
data ScanIdentity
  = KkmBeacon BeaconMac
    -- ^ A KKM beacon this tool can configure, with the MAC the auth
    -- digest is keyed on.
  | ForeignDevice
    -- ^ Definitely another vendor's hardware (the advertised MAC
    -- carries a non-KKM prefix); safe to remember the address and
    -- never reconsider it during this scan.
  | IdentityUnknown
    -- ^ Not decidable yet: an opaque iOS address without a usable
    -- factory name. The name often arrives in a later scan-response
    -- callback, so the address must not be written off.
  deriving (Show, Eq)

-- | Classify one scan result from its 0x2080 service data payload
-- (when the advertisement carried one), its address and its name.
--
-- The service data is the primary signal: it is how KKM's own
-- library recognises its hardware, so a device broadcasting it is a
-- KBeacon regardless of its MAC prefix. The auth MAC is then the
-- advertised address when it is a real MAC (Android reports the true
-- address, which is what the beacon keys its auth digest on), the
-- MAC bytes inside the service data ('kkmExtDataMac', which is how
-- KKM's iOS library recovers MACs, including for renamed beacons),
-- or the factory name suffix. A KBeacon whose MAC cannot be
-- recovered yet stays 'IdentityUnknown' so a later callback carrying
-- the name or the MAC marker can still list it.
--
-- Without service data (a KBeacon slot broadcasting pure
-- iBeacon/Eddystone frames, or any other device) the MAC prefix
-- decides on Android and the factory name on iOS.
--
-- Decision: identify KBeacons in software instead of a hardware scan
-- filter. The tool used to scan with an Android ScanFilter on KKM's
-- 0x2080 service UUID, which matched nothing on real hardware: real
-- KBeacon advertisements carry 0x2080 only in the service DATA field
-- (AD type 0x16), while ScanFilter.setServiceUuid matches the
-- advertised service-class UUID list (AD types 0x02/0x03). KKM's own
-- KBeaconsMgr works around this by OR-ing four filters (Eddystone
-- FEAA, 0x2080, iBeacon and KKM manufacturer data) and then
-- identifying KKM frames while parsing advertisement payloads;
-- hatter delivers the payloads since jappeace/hatter#238, so the
-- tool scans unfiltered and identifies on the 0x2080 service data
-- exactly like KKM does, with the MAC prefix as the fallback for
-- payload-less frames.
identifyScanResult :: Maybe ByteString -> Text -> Text -> ScanIdentity
identifyScanResult maybeExtData address name =
  case macFromAddress address of
    Just mac ->
      if macHasKkmOui mac
        then KkmBeacon mac
        else case maybeExtData of
          Just _ -> KkmBeacon mac
          Nothing -> ForeignDevice
    Nothing ->
      case maybeExtData >>= kkmExtDataMac of
        Just mac -> KkmBeacon mac
        Nothing -> case macFromName name of
          Just mac -> KkmBeacon mac
          Nothing -> IdentityUnknown

-- | KKM's "ext data" service UUID (0x2080), the key under which
-- KBeacons broadcast 'kkmExtDataBattery' and 'kkmExtDataMac' as
-- service data. Pass to 'Hatter.BleAdvertisement.serviceDataForUuid'.
kkmExtDataServiceUuidText :: Text
kkmExtDataServiceUuidText = "00002080-0000-1000-8000-00805F9B34FB"

-- | Battery percent from a 0x2080 service data payload: byte 0,
-- clamped to 100, and only trusted when the payload is longer than
-- two bytes, mirroring KKM's own parser
-- (KBAdvPacketHandler.java: @batteryPercent = byExtenData[0]@ under
-- @length > 2@, capped at 100).
kkmExtDataBattery :: ByteString -> Maybe Int
kkmExtDataBattery extData =
  if BS.length extData > 2
    then Just (min 100 (Word8.toInt (BS.index extData 0)))
    else Nothing

-- | The beacon's MAC recovered from a 0x2080 service data payload:
-- when byte 1 (beacon type flags) is 0 and byte 2 is the marker 1,
-- bytes 3 to 5 are the MAC's low three bytes under KKM's OUI. This
-- mirrors KBAdvPacketHandler.swift, which is how KKM's iOS library
-- learns MACs at all (and the only way for renamed beacons, whose
-- name no longer encodes the MAC).
kkmExtDataMac :: ByteString -> Maybe BeaconMac
kkmExtDataMac extData =
  if BS.length extData > 5
      && BS.index extData 1 == 0x00
      && BS.index extData 2 == 0x01
    then Just (BeaconMac (kkmOuiPrefix <> BS.take 3 (BS.drop 3 extData)))
    else Nothing

-- | Whether the MAC starts with KKM's OUI BC:57:29, ignoring the top
-- two bits of the first byte (masked, BC becomes 3C).
--
-- Decision: mask the two address-type bits instead of comparing the
-- first byte exactly. Real KBeacons use their public IEEE address
-- BC:57:29:xx:xx:xx, but virtual radios must use static random
-- addresses, which require the top two bits set: the emulator test's
-- simulated fleet mimics KKM as FC:57:29:xx:xx:xx. The mask accepts
-- both spellings of the KKM prefix while other vendors stay excluded.
macHasKkmOui :: BeaconMac -> Bool
macHasKkmOui (BeaconMac mac) =
  BS.length mac == 6
    && BS.index mac 0 .&. 0x3F == 0xBC .&. 0x3F
    && BS.index mac 1 == 0x57
    && BS.index mac 2 == 0x29

-- | Connection password, 8 to 16 characters. All KBeacons ship with
-- 'defaultBeaconPassword'.
newtype BeaconPassword = BeaconPassword { unBeaconPassword :: ByteString }
  deriving (Show, Eq)

-- | The factory default password: sixteen ASCII zeros.
defaultBeaconPassword :: BeaconPassword
defaultBeaconPassword = BeaconPassword "0000000000000000"

-- | The 4 challenge bytes the app sends in auth phase 1.
newtype AppRandom = AppRandom { unAppRandom :: ByteString }
  deriving (Show, Eq)

-- | Auth frames carry a bare one-byte header:
-- (DATA_TYPE_AUTH << 4) | PDU_TAG_SINGLE = 0x13.
authFrameHeader :: Word8
authFrameHeader = 0x13

-- | Derive the 4 challenge bytes from a clock reading in picoseconds.
-- The challenge only needs to differ between handshakes, not be
-- unpredictable: it keys a digest of a password the app already
-- knows.
appRandomFromPicoseconds :: Integer -> AppRandom
appRandomFromPicoseconds picoseconds =
  AppRandom (word32BigEndian (picoseconds `mod` 4294967296))

-- | Phase 1 request: header, subtype 0x01, the app's 4 random bytes,
-- and the current UTC time in seconds (the beacon uses it to sync its
-- clock, mirroring the library's default syncUtcTime behaviour). The
-- time wraps at 32 bits like the firmware's epoch counter.
authPhase1Request :: AppRandom -> Integer -> ByteString
authPhase1Request appRandom utcSeconds =
  BS.pack [authFrameHeader, 0x01]
    <> unAppRandom appRandom
    <> word32BigEndian (utcSeconds `mod` 4294967296)

-- | The MD5 proof both sides compute:
-- MD5(reverse(mac) || A9 B1 || random4 || password).
-- The beacon proves knowledge of the password in phase 1 (with the
-- app's random); the app proves it in phase 2 (with the beacon's).
expectedDeviceProof :: BeaconMac -> ByteString -> BeaconPassword -> ByteString
expectedDeviceProof (BeaconMac mac) random4 (BeaconPassword password) =
  MD5.hash
    (BS.reverse mac
      <> BS.pack [0xA9, 0xB1]
      <> random4
      <> password)

-- | Phase 2 request: header, subtype, and our proof over the device's
-- random bytes. The short variant (subtype 0x0C, used when the beacon
-- answered phase 1 with subtype 0x0B) sends the XOR-folded 8 bytes.
authPhase2Request :: BeaconMac -> ByteString -> BeaconPassword -> AuthVariant -> ByteString
authPhase2Request mac deviceRandom password variant =
  let proof = expectedDeviceProof mac deviceRandom password
  in case variant of
    AuthFullDigest ->
      BS.pack [authFrameHeader, 0x02] <> proof
    AuthShortDigest ->
      BS.pack [authFrameHeader, 0x0C] <> xorFoldDigest proof

-- | XOR the two 8-byte halves of an MD5 digest (the short-MTU auth
-- variant).
xorFoldDigest :: ByteString -> ByteString
xorFoldDigest digest =
  let (front, back) = BS.splitAt 8 digest
  in BS.pack (BS.zipWith xor front back)

-- | Bytes of JSON payload that fit in one written frame (the ATT
-- payload minus the 3-byte data-frame header).
newtype FrameBudget = FrameBudget { unFrameBudget :: Int }
  deriving (Show, Eq)

-- | Before the beacon reports its MTU in the auth result: ATT MTU 23
-- gives 20 usable bytes, minus the 3-byte frame header.
defaultFrameBudget :: FrameBudget
defaultFrameBudget = FrameBudget 17

-- | JSON payload budget for a given ATT MTU: the MTU minus 3 (ATT
-- header) minus 3 (frame header). Used both for the MTU the local
-- stack granted and for the one the beacon reports in its auth
-- success frame; nonsensical values fall back to the default.
frameBudgetFromAttMtu :: Int -> FrameBudget
frameBudgetFromAttMtu attMtu =
  let usable = attMtu - 6
  in if usable > unFrameBudget defaultFrameBudget
    then FrameBudget usable
    else defaultFrameBudget

-- | The smaller of two budgets: the link and the beacon each bound
-- the frame size, so writes must satisfy both.
minFrameBudget :: FrameBudget -> FrameBudget -> FrameBudget
minFrameBudget (FrameBudget first) (FrameBudget second) =
  FrameBudget (min first second)

-- | Frame budget honouring BOTH sides of the link: the ATT MTU the
-- local stack actually granted (Nothing when negotiation failed) and
-- the MTU the beacon reports in its auth success frame (0 when the
-- frame carried none). When the local negotiation failed the link is
-- still at ATT 23, so the beacon's usually larger report must not
-- win.
negotiatedFrameBudget :: Maybe Int -> Int -> FrameBudget
negotiatedFrameBudget localMtu beaconReportedMtu =
  let beaconBudget = if beaconReportedMtu > 0
        then frameBudgetFromAttMtu beaconReportedMtu
        else defaultFrameBudget
  in case localMtu of
    Nothing -> defaultFrameBudget
    Just granted -> minFrameBudget (frameBudgetFromAttMtu granted) beaconBudget

-- | Split a JSON message into write-ready frames. Each frame is
-- @header : seqHigh : seqLow : payload@ where the sequence is the
-- byte offset of the fragment and the header combines data type 2
-- (JSON) with the fragment position tag. A message that fits the
-- budget becomes a single frame; larger messages produce
-- start/middle/end frames, and the caller must wait for the beacon's
-- "expect next" ack (cause 4) before sending each follow-up frame.
encodeJsonRequestFrames :: FrameBudget -> ByteString -> [ByteString]
encodeJsonRequestFrames (FrameBudget budget) message =
  let safeBudget = max 1 budget
  in if BS.length message <= safeBudget
    then [BS.pack [jsonFrameHeader PositionSingle, 0x00, 0x00] <> message]
    else encodeFragmentsFrom safeBudget message 0

-- | Recursive fragment encoder for messages over the budget.
encodeFragmentsFrom :: Int -> ByteString -> Int -> [ByteString]
encodeFragmentsFrom budget message offset =
  let remaining = BS.length message - offset
      position = if
        | offset == 0 -> PositionStart
        | remaining <= budget -> PositionEnd
        | otherwise -> PositionMiddle
      chunk = BS.take budget (BS.drop offset message)
      frame = BS.cons (jsonFrameHeader position)
        (word16BigEndian (toInteger offset) <> chunk)
  in case position of
    PositionEnd -> [frame]
    PositionStart -> frame : encodeFragmentsFrom budget message (offset + BS.length chunk)
    PositionMiddle -> frame : encodeFragmentsFrom budget message (offset + BS.length chunk)
    PositionSingle -> [frame]

-- | Position of a fragment within a message (the PDU tag bits).
data FragmentPosition
  = PositionStart
  | PositionMiddle
  | PositionEnd
  | PositionSingle
  deriving (Show, Eq)

-- | Header byte for an app-to-beacon JSON frame (data type 2).
jsonFrameHeader :: FragmentPosition -> Word8
jsonFrameHeader position = (2 `shiftL` 4) .|. fragmentPositionBits position

-- | The two PDU tag bits.
fragmentPositionBits :: FragmentPosition -> Word8
fragmentPositionBits = \case
  PositionStart  -> 0x0
  PositionMiddle -> 0x1
  PositionEnd    -> 0x2
  PositionSingle -> 0x3

-- | Decode the PDU tag bits.
fragmentPositionFromBits :: Word8 -> FragmentPosition
fragmentPositionFromBits bits = if
  | bits .&. 0x3 == 0x0 -> PositionStart
  | bits .&. 0x3 == 0x1 -> PositionMiddle
  | bits .&. 0x3 == 0x2 -> PositionEnd
  | otherwise           -> PositionSingle

-- | Everything the beacon can notify on FEA2, decoded.
data BeaconNotification
  = AuthNotification AuthEvent
  | AckNotification JsonAck
  | ReportNotification ReportFragment
  | UnsupportedNotification Word8
    -- ^ Data types this tool does not use (hex sensor frames).
    -- Carried so the caller can log them loudly instead of guessing.
  deriving (Show, Eq)

-- | Decoded auth-channel frames.
data AuthEvent
  = AuthChallenge AuthVariant ByteString ByteString
    -- ^ Phase 1 response: variant, the device's 4 random bytes, and
    -- its proof digest (16 bytes full, 8 bytes folded).
  | AuthSucceeded Int
    -- ^ Phase 2 accepted; the Int is the beacon's reported ATT MTU
    -- (0 when the frame does not carry one).
  | AuthRejected
    -- ^ 0xF1: wrong password.
  deriving (Show, Eq)

-- | Which digest length the handshake uses.
data AuthVariant
  = AuthFullDigest
  | AuthShortDigest
  deriving (Show, Eq)

-- | A beacon ack for a JSON request (data type 2 notification).
data JsonAck = JsonAck
  { jsonAckSequence :: Int
    -- ^ Byte offset: with cause 4 this is where the next fragment
    -- must start.
  , jsonAckCause :: Int
    -- ^ See the ackCause* constants; anything else is a device error
    -- code.
  , jsonAckPayload :: ByteString
    -- ^ Short responses ride piggyback on a cause-0 ack.
  } deriving (Show, Eq)

-- | Command executed successfully (and for config writes: committed
-- to flash).
ackCauseSuccess :: Int
ackCauseSuccess = 0x0

-- | Send the next fragment starting at the ack's sequence offset.
ackCauseExpectNext :: Int
ackCauseExpectNext = 0x4

-- | Command received; a long response follows as report frames.
ackCauseCommandReceived :: Int
ackCauseCommandReceived = 0x5

-- | Hex command report complete (unused by this tool).
ackCauseReportComplete :: Int
ackCauseReportComplete = 0x6

-- | More report frames follow; keep waiting.
ackCauseReportIncomplete :: Int
ackCauseReportIncomplete = 0x7

-- | One fragment of a long beacon response (data type 3
-- notification).
data ReportFragment = ReportFragment
  { reportFragmentSequence :: Int
    -- ^ Byte offset of this fragment within the full message.
  , reportFragmentPosition :: FragmentPosition
  , reportFragmentData :: ByteString
  } deriving (Show, Eq)

-- | Decode one FEA2 notification.
parseBeaconNotification :: ByteString -> Either Text BeaconNotification
parseBeaconNotification frame =
  case BS.uncons frame of
    Nothing -> Left "empty notification frame"
    Just (header, body) ->
      let dataType = header `shiftR` 4
          position = fragmentPositionFromBits header
      in if
        | dataType == 1 -> fmap AuthNotification (parseAuthEvent body)
        | dataType == 2 -> fmap AckNotification (parseJsonAck body)
        | dataType == 3 -> fmap ReportNotification (parseReportFragment position body)
        | otherwise -> Right (UnsupportedNotification dataType)

-- | Decode the body of an auth notification.
parseAuthEvent :: ByteString -> Either Text AuthEvent
parseAuthEvent body =
  case BS.uncons body of
    Nothing -> Left "empty auth notification"
    Just (subtype, rest) -> if
      | subtype == 0x01 -> parseAuthChallenge AuthFullDigest 16 rest
      | subtype == 0x0B -> parseAuthChallenge AuthShortDigest 8 rest
      | subtype == 0x02 ->
          case BS.uncons rest of
            Just (mtuByte, _) -> Right (AuthSucceeded (Word8.toInt mtuByte))
            Nothing -> Right (AuthSucceeded 0)
      | subtype == 0xF1 -> Right AuthRejected
      | otherwise -> Left ("unknown auth subtype " <> showByte subtype)

-- | Decode the random + proof bytes of a phase 1 response.
parseAuthChallenge :: AuthVariant -> Int -> ByteString -> Either Text AuthEvent
parseAuthChallenge variant proofLength rest =
  if BS.length rest >= 4 + proofLength
    then
      let (deviceRandom, afterRandom) = BS.splitAt 4 rest
      in Right (AuthChallenge variant deviceRandom (BS.take proofLength afterRandom))
    else Left "auth challenge too short"

-- | Decode a JSON ack body: seq(2) window(2) cause(2), then optional
-- piggybacked response bytes.
parseJsonAck :: ByteString -> Either Text JsonAck
parseJsonAck body =
  if BS.length body >= 6
    then Right JsonAck
      { jsonAckSequence = word16At body 0
      , jsonAckCause = word16At body 4
      , jsonAckPayload = BS.drop 6 body
      }
    else Left "json ack shorter than the 6 byte ack head"

-- | Decode a report fragment body: seq(2), then data.
parseReportFragment :: FragmentPosition -> ByteString -> Either Text ReportFragment
parseReportFragment position body =
  if BS.length body >= 2
    then Right ReportFragment
      { reportFragmentSequence = word16At body 0
      , reportFragmentPosition = position
      , reportFragmentData = BS.drop 2 body
      }
    else Left "report fragment shorter than its 2 byte sequence"

-- | Reassembly buffer for a fragmented beacon response.
newtype ReportAssembly = ReportAssembly { unReportAssembly :: ByteString }
  deriving (Show, Eq)

-- | Fresh, empty buffer.
emptyReportAssembly :: ReportAssembly
emptyReportAssembly = ReportAssembly BS.empty

-- | Append one fragment. The fragment's sequence must equal the byte
-- count received so far (the protocol has no reordering). Returns the
-- grown buffer and whether the message is complete.
appendReportFragment
  :: ReportAssembly
  -> ReportFragment
  -> Either Text (ReportAssembly, Bool)
appendReportFragment (ReportAssembly buffered) fragment =
  if reportFragmentSequence fragment /= BS.length buffered
    then Left
      ("report fragment sequence "
        <> Text.pack (show (reportFragmentSequence fragment))
        <> " does not match received byte count "
        <> Text.pack (show (BS.length buffered)))
    else
      let grown = ReportAssembly (buffered <> reportFragmentData fragment)
          complete = case reportFragmentPosition fragment of
            PositionEnd -> True
            PositionSingle -> True
            PositionStart -> False
            PositionMiddle -> False
      in Right (grown, complete)

-- | Ack one received report fragment: header 0x33 (JSON report ack,
-- single), total bytes received, window 1000, cause 0.
reportAckFrame :: Int -> ByteString
reportAckFrame receivedBytes =
  BS.pack [0x33]
    <> word16BigEndian (toInteger receivedBytes)
    <> word16BigEndian 1000
    <> word16BigEndian 0

-- | Request the common and advertisement configuration in one round
-- trip: type is the bitmask common(1) | adv(2). The response carries
-- the battery percent ("btPt") and every slot's parameters
-- ("advObj").
getParaRequestJson :: ByteString
getParaRequestJson = TextEncoding.encodeUtf8 (renderJson
  (JsonObject
    [ ("msg", JsonString "getPara")
    , ("type", JsonNumber 3)
    ]))

-- | A target advertisement period in milliseconds.
newtype AdvPeriodMs = AdvPeriodMs { unAdvPeriodMs :: Int }
  deriving (Show, Eq)

-- | The firmware accepts 100..40000 ms.
validateAdvPeriod :: Int -> Either Text AdvPeriodMs
validateAdvPeriod period =
  if period >= 100 && period <= 40000
    then Right (AdvPeriodMs period)
    else Left "advertisement period must be between 100 and 40000 ms"

-- | Build the config write that sets a slot's advertisement period:
-- {"msg":"cfg","advObj":[{"type":T,"slot":S,"advPrd":P}]}. The
-- firmware keys slot updates on both "slot" and "type", so the slot's
-- current type (learned via 'getParaRequestJson') must be included;
-- omitted fields keep their values.
setAdvPeriodJson :: AdvSlot -> AdvPeriodMs -> ByteString
setAdvPeriodJson slot (AdvPeriodMs periodMs) = TextEncoding.encodeUtf8 (renderJson
  (JsonObject
    [ ("msg", JsonString "cfg")
    , ("advObj", JsonArray
        [ JsonObject
            [ ("type", jsonNumberFromInt (advSlotType slot))
            , ("slot", jsonNumberFromInt (advSlotIndex slot))
            , ("advPrd", jsonNumberFromInt periodMs)
            ]
        ])
    ]))

-- | One advertisement slot as reported by getPara.
data AdvSlot = AdvSlot
  { advSlotIndex :: Int
    -- ^ 0-based slot number.
  , advSlotType :: Int
    -- ^ KBAdvType: 0 disabled, 1 KSensor, 2 EddyUID, 3 EddyTLM,
    -- 4 EddyURL, 5 iBeacon, 6 System, 7 AOA, 8 EBeacon.
  , advSlotPeriodMs :: Maybe Int
    -- ^ Current advertisement period, when reported.
  } deriving (Show, Eq)

-- | The fields this tool reads from a getPara response.
data ParaInfo = ParaInfo
  { paraBatteryPercent :: Maybe Int
  , paraSlots :: [AdvSlot]
  } deriving (Show, Eq)

-- | Parse the reassembled getPara response JSON.
parseParaResponse :: ByteString -> Either Text ParaInfo
parseParaResponse raw = do
  decoded <- decodeUtf8Loud raw
  document <- parseJson decoded
  let battery = lookupField "btPt" document >>= jsonInt
      slotValues = case lookupField "advObj" document >>= jsonArrayItems of
        Just items -> items
        Nothing -> []
  slots <- traverse parseAdvSlot slotValues
  Right ParaInfo { paraBatteryPercent = battery, paraSlots = slots }

-- | Parse one advObj entry.
parseAdvSlot :: JsonValue -> Either Text AdvSlot
parseAdvSlot value =
  case (lookupField "slot" value >>= jsonInt, lookupField "type" value >>= jsonInt) of
    (Just slotIndex, Just slotType) -> Right AdvSlot
      { advSlotIndex = slotIndex
      , advSlotType = slotType
      , advSlotPeriodMs = lookupField "advPrd" value >>= jsonInt
      }
    (Nothing, _) -> Left "advObj entry without a slot number"
    (Just _, Nothing) -> Left "advObj entry without a type"

-- | Pick which slot to configure: slot 0 when the beacon reports it
-- (KKM's demo tooling configures slot 0), otherwise the first
-- reported slot. Beacons reporting no slots cannot be configured.
slotToConfigure :: ParaInfo -> Either Text AdvSlot
slotToConfigure info =
  case filter (\slot -> advSlotIndex slot == 0) (paraSlots info) of
    (zero : _) -> Right zero
    [] -> case paraSlots info of
      (first : _) -> Right first
      [] -> Left "beacon reported no advertisement slots"

-- | Decode UTF-8, surfacing the error instead of replacing bytes:
-- a malformed response means the reassembly went wrong and must be
-- visible.
decodeUtf8Loud :: ByteString -> Either Text Text
decodeUtf8Loud raw =
  case TextEncoding.decodeUtf8' raw of
    Right decoded -> Right decoded
    Left err -> Left ("response is not valid UTF-8: " <> Text.pack (show err))

-- | Big-endian 16-bit word starting at the given offset (bounds
-- already checked by callers).
word16At :: ByteString -> Int -> Int
word16At bytes offset =
  Word8.toInt (BS.index bytes offset) * 256
    + Word8.toInt (BS.index bytes (offset + 1))

-- | One byte of a big-endian encoder: the divMod decomposition keeps
-- every value in [0, 255], so a failed narrowing means the caller
-- exceeded the encoder's range and must crash loudly rather than
-- truncate on the wire.
encoderByte :: Text -> Integer -> Word8
encoderByte label value =
  case Int.toWord8 =<< Integer.toInt value of
    Just byte -> byte
    Nothing -> error (Text.unpack label <> ": byte value " <> show value <> " out of range")

-- | Big-endian encoding of a value in [0, 65535]; larger or negative
-- values crash loudly.
word16BigEndian :: Integer -> ByteString
word16BigEndian value =
  let (high, low) = value `divMod` 256
  in if value < 0 || value > 65535
    then error ("word16BigEndian: " <> show value <> " out of range")
    else BS.pack [encoderByte "word16BigEndian" high, encoderByte "word16BigEndian" low]

-- | Big-endian encoding of a value in [0, 2^32); larger or negative
-- values crash loudly.
word32BigEndian :: Integer -> ByteString
word32BigEndian value =
  let (upper, lower) = value `divMod` 65536
  in if value < 0 || value >= 4294967296
    then error ("word32BigEndian: " <> show value <> " out of range")
    else word16BigEndian upper <> word16BigEndian lower

-- | Hex rendering for error messages.
showByte :: Word8 -> Text
showByte byte = Text.pack (show byte)
