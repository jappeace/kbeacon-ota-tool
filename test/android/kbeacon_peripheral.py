#!/usr/bin/env python3
# Virtual KBeacon Pro fleet for the Android emulator UI test.
#
# Joins the emulator's netsim virtual radio (same mechanism as
# hatter's test/android/ble_peripheral.py) and runs two devices:
#
#   1. "KBPro-F4F5F6": a simulated KBeacon Pro. Advertises like the
#      real hardware (KKM's 0x2080 ext-data UUID only as service
#      data, with a realistic battery byte) and serves the KBeacon
#      configuration GATT protocol on FEA0/FEA1/FEA2: the MD5 auth
#      handshake, getPara reads answered as fragmented report frames,
#      and cfg writes that change the stored advertisement period.
#
#   2. "NotABeacon": a decoy advertising a non-KKM service UUID from
#      a non-KKM address. The app's KKM identity gate must never list
#      it.
#
# The protocol implementation mirrors test/../src/KBeacon/Protocol.hs
# (both were written from KKM's android_kbeaconlib2 sources), so the
# emulator test exercises a full client/server round trip of the real
# wire format.
#
# Markers printed for the test harness:
#   ADVERTISING_STARTED, DECOY_ADVERTISING_STARTED,
#   PERIPHERAL_CONNECTED, PERIPHERAL_DISCONNECTED,
#   AUTH_PHASE1, AUTH_OK, AUTH_FAIL_BAD_PROOF,
#   GET_PARA, SENT_PARA_COMPLETE, CFG_ADV_PRD:<slot>:<periodMs>
#
# Usage: kbeacon_peripheral.py [transport]   (default: android-netsim)

import asyncio
import hashlib
import json
import sys

from bumble.core import UUID, AdvertisingData
from bumble.device import Device
from bumble.gatt import Characteristic, CharacteristicValue, Service
from bumble.hci import Address
from bumble.transport import open_transport

# FC:57:29 mimics KKM's BC:57:29 OUI while keeping the top two bits
# set, which static random BLE addresses require. The app's identity
# gate masks those two bits (Protocol.macHasKkmOui), so this address
# still counts as KKM. The name suffix matches the MAC's low three
# bytes like factory-named KBeacons.
KBEACON_ADDRESS = 'FC:57:29:F4:F5:F6'
KBEACON_NAME = 'KBPro-F4F5F6'
KBEACON_PASSWORD = b'0000000000000000'
KBEACON_BATTERY_PERCENT = 85

DECOY_ADDRESS = 'F0:F1:F2:F3:F4:F5'
DECOY_NAME = 'NotABeacon'
DECOY_SERVICE_UUID = '50DB505C-8AC4-4738-8448-3B1D9CC09CC5'

KKM_EXT_DATA_UUID_16 = 0x2080
KB_CONFIG_SERVICE_UUID = '0000FEA0-0000-1000-8000-00805F9B34FB'
KB_WRITE_CHARACTERISTIC_UUID = '0000FEA1-0000-1000-8000-00805F9B34FB'
KB_NOTIFY_CHARACTERISTIC_UUID = '0000FEA2-0000-1000-8000-00805F9B34FB'

# Report fragments stay well under the negotiated ATT MTU (the app
# requests 251 before subscribing).
REPORT_FRAGMENT_SIZE = 100

AUTH_FACTORS = bytes([0xA9, 0xB1])


def mac_bytes(address):
    return bytes(int(part, 16) for part in address.split(':'))


def auth_proof(address, random4, password):
    reversed_mac = mac_bytes(address)[::-1]
    return hashlib.md5(reversed_mac + AUTH_FACTORS + random4 + password).digest()


class KBeaconProtocolServer:
    """Server side of the KBeacon FEA0 config protocol."""

    def __init__(self, device):
        self.device = device
        self.notify_characteristic = None
        self.device_random = bytes([0x4B, 0x42, 0x53, 0x4D])  # constant is fine for tests
        self.request_buffer = b''
        self.pending_reports = []
        # The mutable "beacon configuration" the cfg writes modify.
        self.slots = [
            {'type': 2, 'slot': 0, 'advPrd': 1280, 'txPwr': 0},
            {'type': 3, 'slot': 1, 'advPrd': 8000, 'txPwr': 0},
        ]

    async def notify(self, payload):
        await self.device.gatt_server.notify_subscribers(
            self.notify_characteristic, payload)

    async def on_write(self, connection, value):
        del connection
        if len(value) == 0:
            return
        header = value[0]
        data_type = header >> 4
        if header == 0x13:
            await self.on_auth_frame(value[1:])
        elif data_type == 2:
            await self.on_json_frame(header & 0x3, value[1:])
        elif data_type == 3:
            await self.on_report_ack(value[1:])
        else:
            print(f'UNEXPECTED_FRAME: {value.hex()}', flush=True)

    async def on_auth_frame(self, body):
        subtype = body[0]
        if subtype == 0x01:
            app_random = body[1:5]
            print('AUTH_PHASE1', flush=True)
            proof = auth_proof(KBEACON_ADDRESS, app_random, KBEACON_PASSWORD)
            await self.notify(bytes([0x13, 0x01]) + self.device_random + proof)
        elif subtype == 0x02:
            expected = auth_proof(KBEACON_ADDRESS, self.device_random, KBEACON_PASSWORD)
            if bytes(body[1:17]) == expected:
                print('AUTH_OK', flush=True)
                # 0xF7 = ATT MTU 247, the value netsim links typically grant.
                await self.notify(bytes([0x13, 0x02, 0xF7]))
            else:
                print('AUTH_FAIL_BAD_PROOF', flush=True)
                await self.notify(bytes([0x13, 0xF1]))
        else:
            print(f'AUTH_UNEXPECTED_SUBTYPE: {subtype:#x}', flush=True)
            await self.notify(bytes([0x13, 0xF1]))

    async def on_json_frame(self, tag, body):
        sequence = (body[0] << 8) | body[1]
        payload = bytes(body[2:])
        if sequence != len(self.request_buffer):
            print(f'REQUEST_SEQUENCE_MISMATCH: {sequence} != {len(self.request_buffer)}',
                  flush=True)
            self.request_buffer = b''
            return
        self.request_buffer += payload
        if tag in (0x0, 0x1):  # start or middle: ack expect-next (cause 4)
            await self.send_ack(len(self.request_buffer), 4, b'')
            return
        message = self.request_buffer
        self.request_buffer = b''
        await self.on_json_message(message)

    async def send_ack(self, sequence, cause, extra):
        frame = bytes([0x23,
                       (sequence >> 8) & 0xFF, sequence & 0xFF,
                       0x00, 0x01,
                       (cause >> 8) & 0xFF, cause & 0xFF]) + extra
        await self.notify(frame)

    async def on_json_message(self, message):
        try:
            request = json.loads(message.decode('utf-8'))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            print(f'BAD_JSON: {error}', flush=True)
            await self.send_ack(0, 1, b'')
            return
        if request.get('msg') == 'getPara':
            print('GET_PARA', flush=True)
            await self.send_para_response()
        elif request.get('msg') == 'cfg':
            await self.on_cfg(request)
        else:
            print(f'UNKNOWN_MSG: {request}', flush=True)
            await self.send_ack(0, 1, b'')

    async def send_para_response(self):
        response = json.dumps(
            {
                'model': 'KBSim',
                'ver': '5.22',
                'btPt': KBEACON_BATTERY_PERCENT,
                'name': KBEACON_NAME,
                'maxSlot': 5,
                'pwd': '',
                'advObj': self.slots,
            },
            separators=(',', ':')).encode('utf-8')
        # Long-response path: command-received ack (cause 5), then the
        # payload as dataType-3 report frames, each waiting for the
        # client's 0x33 report ack.
        self.pending_reports = []
        offset = 0
        while offset < len(response):
            chunk = response[offset:offset + REPORT_FRAGMENT_SIZE]
            last = offset + len(chunk) >= len(response)
            if offset == 0 and last:
                tag = 0x3
            elif offset == 0:
                tag = 0x0
            elif last:
                tag = 0x2
            else:
                tag = 0x1
            frame = bytes([(3 << 4) | tag,
                           (offset >> 8) & 0xFF, offset & 0xFF]) + chunk
            self.pending_reports.append(frame)
            offset += len(chunk)
        await self.send_ack(0, 5, b'')
        await self.send_next_report()

    async def send_next_report(self):
        if self.pending_reports:
            frame = self.pending_reports.pop(0)
            await self.notify(frame)
            if not self.pending_reports:
                print('SENT_PARA_COMPLETE', flush=True)

    async def on_report_ack(self, body):
        # byte0..1 seq, byte2..3 window, byte4..5 cause
        cause = (body[4] << 8) | body[5] if len(body) >= 6 else 1
        if cause == 0:
            await self.send_next_report()
        else:
            print(f'REPORT_ACK_ERROR: cause {cause}', flush=True)

    async def on_cfg(self, request):
        print(f'CFG_RECEIVED: {json.dumps(request, separators=(",", ":"))}', flush=True)
        adv_objects = request.get('advObj')
        if not isinstance(adv_objects, list) or not adv_objects:
            await self.send_ack(0, 2, b'')
            return
        for entry in adv_objects:
            slot = entry.get('slot')
            period = entry.get('advPrd')
            if slot is None or period is None:
                await self.send_ack(0, 2, b'')
                return
            matched = False
            for stored in self.slots:
                if stored['slot'] == slot:
                    stored.update(entry)
                    matched = True
            if not matched:
                await self.send_ack(0, 2, b'')
                return
            print(f'CFG_ADV_PRD:{slot}:{period}', flush=True)
        await self.send_ack(0, 0, b'')


async def run_kbeacon(transport_name):
    async with await open_transport(transport_name) as hci_transport:
        device = Device.with_hci(
            KBEACON_NAME,
            Address(KBEACON_ADDRESS),
            hci_transport.source,
            hci_transport.sink,
        )
        server = KBeaconProtocolServer(device)

        write_characteristic = Characteristic(
            KB_WRITE_CHARACTERISTIC_UUID,
            Characteristic.Properties.WRITE
            | Characteristic.Properties.WRITE_WITHOUT_RESPONSE,
            Characteristic.WRITEABLE,
        )
        write_characteristic.value = CharacteristicValue(write=server.on_write)

        notify_characteristic = Characteristic(
            KB_NOTIFY_CHARACTERISTIC_UUID,
            Characteristic.Properties.NOTIFY,
            Characteristic.READABLE,
            b'',
        )
        server.notify_characteristic = notify_characteristic

        device.add_service(Service(
            KB_CONFIG_SERVICE_UUID,
            [write_characteristic, notify_characteristic],
        ))

        # Advertisement: real KKM hardware carries the 0x2080 ext-data
        # UUID ONLY as a service-data element (AD type 0x16, first
        # payload byte is the battery percent), never in the 16-bit
        # service-class UUID list. The tool once scan-filtered on that
        # UUID with Android's setServiceUuid, which matches the
        # service-class list alone, so it saw nothing in the field
        # while this simulation (which then also advertised the UUID
        # in the class list) kept CI green. Do not "help" a scan
        # filter by re-adding the UUID to the class list: this frame
        # must stay as unmatchable as the real one. The name travels
        # in the scan response.
        ext_uuid_le = KKM_EXT_DATA_UUID_16.to_bytes(2, 'little')
        low_mac = mac_bytes(KBEACON_ADDRESS)[3:6]
        ext_service_data = bytes([KBEACON_BATTERY_PERCENT, 0x00, 0x01]) + low_mac
        device.advertising_data = bytes(AdvertisingData([
            (AdvertisingData.FLAGS, bytes([0x06])),
            (AdvertisingData.SERVICE_DATA_16_BIT_UUID, ext_uuid_le + ext_service_data),
        ]))
        scan_response = bytes(AdvertisingData([
            (AdvertisingData.COMPLETE_LOCAL_NAME, KBEACON_NAME.encode('utf-8')),
        ]))
        device.scan_response_data = scan_response

        device.on('connection', lambda connection:
                  print(f'PERIPHERAL_CONNECTED: {connection}', flush=True))
        device.on('disconnection', lambda *args:
                  print('PERIPHERAL_DISCONNECTED', flush=True))

        await device.power_on()
        await device.start_advertising(
            auto_restart=True,
            scan_response_data=scan_response,
        )
        print('ADVERTISING_STARTED', flush=True)
        await asyncio.get_running_loop().create_future()


async def run_decoy(transport_name):
    async with await open_transport(transport_name) as hci_transport:
        device = Device.with_hci(
            DECOY_NAME,
            Address(DECOY_ADDRESS),
            hci_transport.source,
            hci_transport.sink,
        )
        device.advertising_data = bytes(AdvertisingData([
            (AdvertisingData.FLAGS, bytes([0x06])),
            (
                AdvertisingData.COMPLETE_LIST_OF_128_BIT_SERVICE_CLASS_UUIDS,
                UUID(DECOY_SERVICE_UUID).to_bytes(),
            ),
        ]))
        scan_response = bytes(AdvertisingData([
            (AdvertisingData.COMPLETE_LOCAL_NAME, DECOY_NAME.encode('utf-8')),
        ]))
        device.scan_response_data = scan_response
        await device.power_on()
        await device.start_advertising(
            auto_restart=True,
            scan_response_data=scan_response,
        )
        print('DECOY_ADVERTISING_STARTED', flush=True)
        await asyncio.get_running_loop().create_future()


async def run_fleet(transport_name):
    await asyncio.gather(
        run_kbeacon(transport_name),
        run_decoy(transport_name),
    )


def main():
    transport_name = sys.argv[1] if len(sys.argv) > 1 else 'android-netsim'
    asyncio.run(run_fleet(transport_name))


if __name__ == '__main__':
    main()
