{-# LANGUAGE OverloadedStrings #-}
module Main where

import Data.IORef (newIORef, readIORef, writeIORef, modifyIORef')
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text, pack)
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
import Hatter.Ble (BleState, BleScanResult(..), checkBleAdapter, startBleScan, stopBleScan)
import Hatter.Permission (PermissionState, Permission(..), requestPermission)
import Hatter.Widget
  ( ButtonConfig(..)
  , InputType(..)
  , TextConfig(..)
  , TextInputConfig(..)
  , Widget(..)
  , column
  , row
  , scrollColumn
  , text
  , button
  )

data ScannedBeacon = ScannedBeacon
  { sbName    :: Text
  , sbAddress :: Text
  , sbRssi    :: Int
  }

-- Beacons closer than this RSSI threshold are ignored (same as original Scanner.kt)
rssiThreshold :: Int
rssiThreshold = -50

main :: IO (Ptr AppContext)
main = do
  platformLog "kbeacon-ota-hatter starting"
  actionState  <- newActionState
  beaconsRef   <- newIORef ([] :: [ScannedBeacon])
  seenMacsRef  <- newIORef (Set.empty :: Set Text)
  advPeriodRef <- newIORef ("1000" :: Text)
  isScanningRef <- newIORef False
  bleStateRef  <- newIORef (Nothing :: Maybe BleState)
  permissionStateRef <- newIORef (Nothing :: Maybe PermissionState)
  redrawRef    <- newIORef (pure () :: IO ())

  (onRequestPerms, onCheckAdapter, onStartScan, onStopScan, onPeriodChange) <-
    runActionM actionState $ do

      perms <- createAction $ do
        mPermissionState <- readIORef permissionStateRef
        case mPermissionState of
          Nothing -> platformLog "permission state not ready"
          -- BLE scanning needs BLUETOOTH_SCAN on API 31+ and ACCESS_FINE_LOCATION
          -- on older devices; request both, location after bluetooth resolves.
          Just permissionState ->
            requestPermission permissionState PermissionBluetooth $ \bluetoothStatus -> do
              platformLog ("BLUETOOTH_SCAN permission: " <> pack (show bluetoothStatus))
              requestPermission permissionState PermissionLocation $ \locationStatus ->
                platformLog ("ACCESS_FINE_LOCATION permission: " <> pack (show locationStatus))

      checkAdapter <- createAction $ do
        status <- checkBleAdapter
        platformLog ("BLE adapter status: " <> pack (show status))

      startScan <- createAction $ do
        mBleState <- readIORef bleStateRef
        case mBleState of
          Nothing -> platformLog "BLE state not ready"
          Just bleState -> do
            writeIORef beaconsRef []
            writeIORef seenMacsRef Set.empty
            writeIORef isScanningRef True
            startBleScan bleState $ \result -> do
              let rssi = bsrRssi result
                  mac  = bsrDeviceAddress result
              if rssi < rssiThreshold
                then platformLog ("ignored " <> mac <> " rssi=" <> pack (show rssi))
                else do
                  seen <- readIORef seenMacsRef
                  if Set.member mac seen
                    then platformLog ("already seen " <> mac)
                    else do
                      modifyIORef' seenMacsRef (Set.insert mac)
                      modifyIORef' beaconsRef
                        (ScannedBeacon (bsrDeviceName result) mac rssi :)
                      redraw <- readIORef redrawRef
                      redraw
            platformLog "BLE scan started"

      stopScan <- createAction $ do
        mBleState <- readIORef bleStateRef
        case mBleState of
          Nothing -> pure ()
          Just bleState -> do
            stopBleScan bleState
            writeIORef isScanningRef False
            platformLog "BLE scan stopped"

      periodChange <- createOnChange $ \newValue ->
        writeIORef advPeriodRef newValue

      pure (perms, checkAdapter, startScan, stopScan, periodChange)

  ctxPtr <- startMobileApp MobileApp
    { maContext     = loggingMobileContext
    , maView        = \userState -> do
        writeIORef redrawRef (userRequestRedraw userState)
        beacons    <- readIORef beaconsRef
        advPeriod  <- readIORef advPeriodRef
        isScanning <- readIORef isScanningRef
        pure $ appView
          beacons advPeriod isScanning
          onRequestPerms onCheckAdapter onStartScan onStopScan onPeriodChange
    , maActionState = actionState
    }

  appCtx <- derefAppContext ctxPtr
  writeIORef bleStateRef (Just (acBleState appCtx))
  writeIORef permissionStateRef (Just (acPermissionState appCtx))
  pure ctxPtr

appView
  :: [ScannedBeacon]
  -> Text
  -> Bool
  -> Action -> Action -> Action -> Action -> OnChange
  -> Widget
appView beacons advPeriod isScanning
        onRequestPerms onCheckAdapter onStartScan onStopScan onPeriodChange =
  column
    [ row
        [ button "Request Permissions" onRequestPerms
        , button "Check Adapter"       onCheckAdapter
        ]
    , TextInput TextInputConfig
        { tiInputType  = InputNumber
        , tiHint       = "Adv interval (ms)"
        , tiValue      = advPeriod
        , tiOnChange   = onPeriodChange
        , tiFontConfig = Nothing
        , tiAutoFocus  = False
        }
    , row
        [ button "Start Scan" onStartScan
        , button "Stop Scan"  onStopScan
        ]
    , text ("Scanning: " <> if isScanning then "yes" else "no")
    , text (pack (show (length beacons)) <> " device(s) found")
    , scrollColumn (map beaconRow (reverse beacons))
    ]

beaconRow :: ScannedBeacon -> Widget
beaconRow beacon = row
  [ text (sbName beacon)
  , text (" | " <> sbAddress beacon)
  , text (" | RSSI: " <> pack (show (sbRssi beacon)))
  ]
