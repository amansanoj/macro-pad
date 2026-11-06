@preconcurrency import CoreBluetooth
import Foundation
import Observation

enum ConnectionState: Equatable {
    case disconnected
    case scanning
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case failed(String)

    var title: String {
        switch self {
        case .disconnected: "Disconnected"
        case .scanning: "Scanning"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .reconnecting(let attempt): "Reconnecting (attempt \(attempt))"
        case .failed: "Failed"
        }
    }

    var symbol: String {
        switch self {
        case .connected: "checkmark.circle.fill"
        case .scanning, .connecting, .reconnecting: "arrow.trianglehead.2.clockwise.rotate.90"
        case .failed: "exclamationmark.triangle.fill"
        case .disconnected: "circle"
        }
    }
}

enum BLEConnectionIntent: CaseIterable, Sendable {
    case disconnected
    case maintainConnection
    case rejectedDevice

    func allowsReconnect(automaticallyReconnect: Bool, hasSelectedDevice: Bool) -> Bool {
        self == .maintainConnection && automaticallyReconnect && hasSelectedDevice
    }
}

@MainActor
@Observable
final class BLEController: NSObject {
    private(set) var connectionState: ConnectionState = .disconnected
    private(set) var bluetoothMessage = "Bluetooth status is not yet known."
    private(set) var discoveredDeviceName: String?
    var selectedPeripheralID: UUID?
    var automaticallyReconnect = true {
        didSet {
            if !automaticallyReconnect {
                reconnectTask?.cancel()
            }
        }
    }
    var onEvent: ((ButtonEvent) -> Void)?
    var onSelectedPeripheral: ((UUID, String) -> Void)?
    var onConnectionReset: (() -> Void)?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var eventCharacteristic: CBCharacteristic?
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    private var connectionIntent: BLEConnectionIntent = .disconnected
    private let serviceUUID = CBUUID(string: BLEProtocol.serviceUUID)
    private let characteristicUUID = CBUUID(string: BLEProtocol.eventCharacteristicUUID)

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func connect() {
        connectionIntent = .maintainConnection
        reconnectTask?.cancel()
        guard central.state == .poweredOn else {
            updateBluetoothMessage()
            return
        }

        if let selectedPeripheralID,
           let known = central.retrievePeripherals(withIdentifiers: [selectedPeripheralID]).first {
            connectionState = reconnectAttempt == 0 ? .connecting : .reconnecting(attempt: reconnectAttempt)
            peripheral = known
            known.delegate = self
            central.connect(known)
            return
        }

        connectionState = .scanning
        bluetoothMessage = "Looking for a device advertising the macro-pad service."
        central.scanForPeripherals(withServices: [serviceUUID], options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
    }

    func disconnect() {
        connectionIntent = .disconnected
        reconnectTask?.cancel()
        reconnectAttempt = 0
        central.stopScan()
        resetEventConnection()
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        } else {
            connectionState = .disconnected
        }
    }

    func forgetDevice() {
        disconnect()
        selectedPeripheralID = nil
        discoveredDeviceName = nil
        peripheral = nil
    }

    func restoreAutomaticConnection() {
        guard automaticallyReconnect, selectedPeripheralID != nil else { return }
        connect()
    }

    private func scheduleReconnect() {
        guard connectionIntent.allowsReconnect(
            automaticallyReconnect: automaticallyReconnect,
            hasSelectedDevice: selectedPeripheralID != nil
        ) else { return }
        reconnectAttempt += 1
        connectionState = .reconnecting(attempt: reconnectAttempt)
        let delay = min(pow(2.0, Double(reconnectAttempt - 1)), 30)
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled,
                  self?.automaticallyReconnect == true,
                  self?.connectionIntent == .maintainConnection else { return }
            self?.connect()
        }
    }

    private func rejectConnectedDevice(_ message: String) {
        connectionIntent = .rejectedDevice
        reconnectTask?.cancel()
        resetEventConnection()
        connectionState = .failed(message)
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
    }

    private func resetEventConnection() {
        eventCharacteristic = nil
        onConnectionReset?()
    }

    private func updateBluetoothMessage() {
        switch central.state {
        case .poweredOn:
            bluetoothMessage = "Bluetooth is available."
        case .poweredOff:
            bluetoothMessage = "Turn on Bluetooth in System Settings, then reconnect."
            connectionState = .failed("Bluetooth is turned off.")
        case .unauthorized:
            bluetoothMessage = "Allow Bluetooth access in System Settings → Privacy & Security → Bluetooth."
            connectionState = .failed("Bluetooth access is not authorized.")
        case .unsupported:
            bluetoothMessage = "This Mac does not support Bluetooth Low Energy."
            connectionState = .failed("Bluetooth Low Energy is unavailable.")
        case .resetting:
            bluetoothMessage = "Bluetooth is resetting. macro-pad will retry when it becomes available."
        case .unknown:
            bluetoothMessage = "Bluetooth status is not yet known."
        @unknown default:
            bluetoothMessage = "Bluetooth reported an unknown state."
        }
    }
}

extension BLEController: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        updateBluetoothMessage()
        if central.state == .poweredOn,
           connectionIntent == .maintainConnection,
           automaticallyReconnect,
           selectedPeripheralID != nil {
            connect()
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard connectionIntent == .maintainConnection,
              advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] != nil else { return }
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        discoveredDeviceName = peripheral.name ?? BLEProtocol.deviceName
        onSelectedPeripheral?(peripheral.identifier, discoveredDeviceName ?? BLEProtocol.deviceName)
        connectionState = .connecting
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard connectionIntent == .maintainConnection else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        reconnectTask?.cancel()
        reconnectAttempt = 0
        resetEventConnection()
        selectedPeripheralID = peripheral.identifier
        discoveredDeviceName = peripheral.name ?? BLEProtocol.deviceName
        connectionState = .connecting
        bluetoothMessage = "Discovering the event service."
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: (any Error)?) {
        bluetoothMessage = error?.localizedDescription ?? "The connection attempt failed."
        if connectionIntent == .maintainConnection {
            scheduleReconnect()
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        timestamp: CFAbsoluteTime, isReconnecting: Bool, error: (any Error)?) {
        resetEventConnection()
        bluetoothMessage = error?.localizedDescription ?? "The device disconnected."
        switch connectionIntent {
        case .disconnected:
            connectionState = .disconnected
        case .maintainConnection:
            connectionState = .disconnected
            scheduleReconnect()
        case .rejectedDevice:
            break
        }
    }
}

extension BLEController: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        if let error {
            connectionState = .failed(error.localizedDescription)
            central.cancelPeripheralConnection(peripheral)
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            rejectConnectedDevice("The required macro-pad service was not found.")
            return
        }
        peripheral.discoverCharacteristics([characteristicUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: (any Error)?) {
        if let error {
            connectionState = .failed(error.localizedDescription)
            central.cancelPeripheralConnection(peripheral)
            return
        }
        guard let characteristic = service.characteristics?.first(where: { $0.uuid == characteristicUUID }),
              characteristic.properties.contains(.notify) else {
            rejectConnectedDevice("The event notification characteristic is missing.")
            return
        }
        eventCharacteristic = characteristic
        peripheral.setNotifyValue(true, for: characteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: (any Error)?) {
        if let error {
            rejectConnectedDevice(error.localizedDescription)
            return
        }
        guard characteristic.isNotifying else {
            rejectConnectedDevice("The device refused event notifications.")
            return
        }
        connectionState = .connected
        bluetoothMessage = "Receiving button events."
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                    error: (any Error)?) {
        guard error == nil, characteristic.uuid == characteristicUUID,
              let data = characteristic.value else {
            if let error { bluetoothMessage = error.localizedDescription }
            return
        }
        do {
            onEvent?(try ButtonEvent(data: data))
        } catch {
            bluetoothMessage = error.localizedDescription
        }
    }
}
