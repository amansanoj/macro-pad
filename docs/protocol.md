# BLE protocol

macro-pad uses a custom BLE GATT service because the ESP32-WROOM-32 is an input sensor, while the Mac owns configurable actions and their permissions. BLE HID would make the firmware impersonate a keyboard, complicate per-key configuration, and couple hardware events to executable behavior.

## GATT layout

| Item | UUID | Properties |
| --- | --- | --- |
| Event service | `7A4D1000-5A7E-4D2F-9C6B-4B0A3E6D0100` | Primary service |
| Event characteristic | `7A4D1001-5A7E-4D2F-9C6B-4B0A3E6D0100` | Read, notify |

The advertised name is `macro-pad`, but the macOS app filters on the service UUID and stores the selected CoreBluetooth peripheral identifier. A name match alone is never trusted.

## Version 1 packet

Every notification is exactly five bytes.

| Offset | Field | Values |
| --- | --- | --- |
| 0 | Protocol version | `0x01` |
| 1 | Message type | `0x01` event, `0x02` state synchronization |
| 2 | Key identifier | `0x01` through `0x04` |
| 3 | State | `0x00` released, `0x01` pressed |
| 4 | Sequence | Wrapping unsigned byte |

Normal key-down packets execute an assignment once. Key-up updates state only. A repeated sequence for the same key is ignored. State-synchronization packets update pressed state but never execute an action.

On each connection, firmware suppresses normal notifications for 75 ms while debounce state settles, then sends one state-synchronization packet per key. This prevents a key already held during connection from launching its assignment.

Malformed lengths, message types, keys, states, and unsupported versions are rejected by the app. The payload never contains application paths, URLs, shortcuts, shell commands, or other executable content.

## Security model

NimBLE requests bonding and encryption with the ESP32's no-input/no-output capability. This is BLE Just Works pairing: it protects a bonded connection from passive observation but does not provide authenticated first-pairing protection. Keep initial pairing physically controlled. The app additionally requires the fixed service and characteristic UUIDs and remembers CoreBluetooth's peripheral identifier, but a sufficiently capable nearby attacker can impersonate an unpaired or forgotten device.

CoreBluetooth does not guarantee indefinite background operation or reconnection. The app retries with bounded exponential backoff while it remains running.
