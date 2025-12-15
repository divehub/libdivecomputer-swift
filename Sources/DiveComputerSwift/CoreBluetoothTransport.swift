@preconcurrency import Foundation
import os

#if canImport(CoreBluetooth)
    import CoreBluetooth

    extension Notification.Name {
        static let bluetoothPeripheralDisconnected = Notification.Name(
            "bluetoothPeripheralDisconnected")
    }

    @MainActor
    public final class CoreBluetoothTransport: NSObject, BluetoothTransport {
        private var central: CBCentralManager!
        private var scanContinuation: AsyncThrowingStream<BluetoothDiscovery, Error>.Continuation?
        private var stateCallbacks: [(BluetoothState) -> Void] = []

        public var bluetoothState: AsyncStream<BluetoothState> {
            AsyncStream { continuation in
                // Yield current state immediately
                let currentState = self.mapState(self.central.state)
                continuation.yield(currentState)

                // Store callback to yield future updates
                // let uuid = UUID()
                self.stateCallbacks.append { state in
                    continuation.yield(state)
                }

                // Note: Simple callback array approach.
                // In a more robust impl, we might want a way to remove specific callbacks on termination,
                // but AsyncStream doesn't provide an easy onTermination hook for the producer side explicitly
                // without managing continuations manually.
                // For now, this is acceptable for the app's lifecycle or we can use a multicast approach if needed.
                // However, capturing continuation in a closure added to an array is the simplest way to broadcast.
            }
        }

        private var scanDescriptors: [DiveComputerDescriptor] = []
        private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
        private var peripheralDescriptors: [UUID: DiveComputerDescriptor] = [:]
        private var connectContinuations: [UUID: CheckedContinuation<BluetoothLink, Error>] = [:]
        private var readinessContinuation: CheckedContinuation<Void, Error>?
        private var scanTimeoutTask: Task<Void, Never>?

        public override init() {
            super.init()
            central = CBCentralManager(delegate: self, queue: nil)
        }

        public func scan(descriptors: [DiveComputerDescriptor], timeout: Duration)
            -> AsyncThrowingStream<BluetoothDiscovery, Error>
        {
            scanDescriptors = descriptors

            return AsyncThrowingStream { continuation in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        try await waitUntilReady()
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }

                    scanContinuation = continuation
                    let services = Array(Set(descriptors.flatMap { $0.serviceUUIDs })).map {
                        $0.cbUUID
                    }
                    Logger.bluetooth.info(
                        "🔍 Starting BLE scan for services: \(services.map { $0.uuidString })")
                    Logger.bluetooth.info("🔍 Scanning for \(descriptors.count) descriptor(s)")
                    central.scanForPeripherals(
                        withServices: services.isEmpty ? nil : services,
                        options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
                    )

                    scanTimeoutTask?.cancel()
                    scanTimeoutTask = Task { @MainActor [weak self] in
                        try? await Task.sleep(for: timeout)
                        self?.stopScan()
                    }
                }
            }
        }

        public func stopScan() {
            central.stopScan()
            scanTimeoutTask?.cancel()
            scanTimeoutTask = nil
            scanContinuation?.finish()
            scanContinuation = nil
        }

        public func connect(_ discovery: BluetoothDiscovery) async throws -> BluetoothLink {
            Logger.bluetooth.info("🔌 CoreBluetoothTransport: Connecting to \(discovery.id)")
            try await waitUntilReady()
            let peripheral: CBPeripheral?
            if let cached = discoveredPeripherals[discovery.id] {
                Logger.bluetooth.info("🔌 CoreBluetoothTransport: Using cached peripheral")
                peripheral = cached
            } else {
                Logger.bluetooth.info(
                    "🔌 CoreBluetoothTransport: Retrieving peripheral by identifier")
                peripheral = central.retrievePeripherals(withIdentifiers: [discovery.id]).first
            }

            guard let target = peripheral else {
                Logger.bluetooth.error("❌ CoreBluetoothTransport: Peripheral not found")
                throw BluetoothTransportError.peripheralUnavailable
            }

            peripheralDescriptors[target.identifier] = discovery.descriptor
            Logger.bluetooth.info(
                "🔌 CoreBluetoothTransport: Initiating connection to \(target.name ?? "unnamed")...")

            return try await withCheckedThrowingContinuation { continuation in
                connectContinuations[target.identifier] = continuation
                central.connect(target)
            }
        }

        private func waitUntilReady() async throws {
            switch central.state {
            case .poweredOn:
                return
            case .poweredOff:
                throw BluetoothTransportError.poweredOff
            case .unauthorized:
                throw BluetoothTransportError.unauthorized
            case .unsupported:
                throw BluetoothTransportError.unsupported
            case .unknown, .resetting:
                break
            @unknown default:
                break
            }

            try await withCheckedThrowingContinuation { continuation in
                readinessContinuation = continuation
            }
        }
    }

    // MARK: - CBCentralManagerDelegate

    extension CoreBluetoothTransport: @MainActor CBCentralManagerDelegate {
        public func centralManagerDidUpdateState(_ central: CBCentralManager) {
            let newState = mapState(central.state)
            Logger.bluetooth.info(
                "📶 Bluetooth state: \(central.state.rawValue) - \(newState)"
            )

            // Broadcast to all streams
            for callback in stateCallbacks {
                callback(newState)
            }

            guard let continuation = readinessContinuation else { return }

            switch central.state {
            case .poweredOn:
                continuation.resume()
            case .unauthorized:
                continuation.resume(throwing: BluetoothTransportError.unauthorized)
            case .unsupported:
                continuation.resume(throwing: BluetoothTransportError.unsupported)
            case .poweredOff:
                continuation.resume(throwing: BluetoothTransportError.poweredOff)
            default:
                // For other states (unknown, resetting), we wait.
                // BUT for the stream, we already yielded.
                // For connection readiness, we probably still want to wait or fail?
                // Existing logic sends unsupported for default, which is fine for connection readiness.
                continuation.resume(throwing: BluetoothTransportError.unsupported)
            }

            readinessContinuation = nil
        }

        private func mapState(_ state: CBManagerState) -> BluetoothState {
            switch state {
            case .unknown: return .unknown
            case .resetting: return .resetting
            case .unsupported: return .unsupported
            case .unauthorized: return .unauthorized
            case .poweredOff: return .poweredOff
            case .poweredOn: return .poweredOn
            @unknown default: return .unknown
            }
        }

        public func centralManager(
            _ central: CBCentralManager,
            didDiscover peripheral: CBPeripheral,
            advertisementData: [String: Any],
            rssi RSSI: NSNumber
        ) {
            Logger.bluetooth.info(
                "📱 Discovered peripheral: \(peripheral.name ?? "Unknown") (\(peripheral.identifier))"
            )
            Logger.bluetooth.info("📱 Advertisement data: \(advertisementData)")
            guard let descriptor = matchDescriptor(for: advertisementData) else {
                Logger.bluetooth.warning("⚠️ No matching descriptor for this peripheral")
                return
            }
            discoveredPeripherals[peripheral.identifier] = peripheral
            peripheralDescriptors[peripheral.identifier] = descriptor

            let advertised =
                (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
                .map { BluetoothUUID($0.uuidString) }
            let discovery = BluetoothDiscovery(
                id: peripheral.identifier,
                descriptor: descriptor,
                name: peripheral.name
                    ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String),
                rssi: RSSI.intValue,
                advertisedServices: advertised
            )
            scanContinuation?.yield(discovery)
        }

        public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral)
        {
            Logger.bluetooth.info(
                "✅ CoreBluetoothTransport: Connected to \(peripheral.name ?? "unnamed") (\(peripheral.identifier))"
            )
            guard let descriptor = peripheralDescriptors[peripheral.identifier],
                let continuation = connectContinuations.removeValue(forKey: peripheral.identifier)
            else {
                Logger.bluetooth.info(
                    "⚠️ CoreBluetoothTransport: No continuation found for peripheral")
                return
            }

            let link = CoreBluetoothLink(
                peripheral: peripheral, descriptor: descriptor, central: central)
            Task { @MainActor in
                do {
                    try await link.prepare()
                    Logger.bluetooth.info(
                        "✅ CoreBluetoothTransport: Link prepared, resuming continuation")
                    continuation.resume(returning: link)
                } catch {
                    Logger.bluetooth.error(
                        "❌ CoreBluetoothTransport: Link preparation failed: \(error)")
                    continuation.resume(throwing: error)
                }
            }
        }

        public func centralManager(
            _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?
        ) {
            Logger.bluetooth.info(
                "❌ CoreBluetoothTransport: Failed to connect to \(peripheral.name ?? "unnamed"): \(error?.localizedDescription ?? "unknown error")"
            )
            guard let continuation = connectContinuations.removeValue(forKey: peripheral.identifier)
            else { return }
            continuation.resume(throwing: error ?? BluetoothTransportError.peripheralUnavailable)
        }

        public func centralManager(
            _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
            error: Error?
        ) {
            Logger.bluetooth.info(
                "🔌❌ CoreBluetoothTransport: Peripheral disconnected: \(peripheral.name ?? "unnamed")"
            )
            if let continuation = connectContinuations.removeValue(forKey: peripheral.identifier) {
                continuation.resume(throwing: error ?? BluetoothTransportError.closed)
            }
            // Notify any active links about the disconnection
            Task { @MainActor in
                NotificationCenter.default.post(
                    name: .bluetoothPeripheralDisconnected,
                    object: peripheral.identifier
                )
            }
        }

        private func stateDescription(_ state: CBManagerState) -> String {
            switch state {
            case .unknown: return "unknown"
            case .resetting: return "resetting"
            case .unsupported: return "unsupported"
            case .unauthorized: return "unauthorized"
            case .poweredOff: return "powered off"
            case .poweredOn: return "powered on"
            @unknown default: return "unknown state"
            }
        }

        private func matchDescriptor(for advertisementData: [String: Any])
            -> DiveComputerDescriptor?
        {
            let uuids =
                (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
                + (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])

            guard !scanDescriptors.isEmpty else { return nil }
            for descriptor in scanDescriptors {
                if uuids.contains(where: { uuid in
                    descriptor.serviceUUIDs.contains(BluetoothUUID(uuid.uuidString))
                }) {
                    return descriptor
                }
            }
            return nil
        }
    }

    // MARK: - CoreBluetoothLink

    @MainActor
    final class CoreBluetoothLink: NSObject, BluetoothLink {
        let descriptor: DiveComputerDescriptor
        let peripheral: CBPeripheral
        private weak var central: CBCentralManager?
        private var serviceContinuation: CheckedContinuation<Void, Error>?
        private var characteristicContinuations: [CBUUID: CheckedContinuation<Void, Error>] = [:]
        private var characteristicMap: [BluetoothCharacteristic: CBCharacteristic] = [:]
        private var readContinuations: [BluetoothCharacteristic: CheckedContinuation<Data, Error>] =
            [:]
        private var writeContinuations:
            [BluetoothCharacteristic: CheckedContinuation<Void, Error>] = [:]
        private var notificationContinuations:
            [BluetoothCharacteristic: AsyncThrowingStream<Data, Error>.Continuation] = [:]
        private var notificationStateContinuations:
            [BluetoothCharacteristic: CheckedContinuation<Void, Error>] = [:]
        private var isClosed = false
        private var disconnectionObserver: NSObjectProtocol?

        init(
            peripheral: CBPeripheral, descriptor: DiveComputerDescriptor, central: CBCentralManager
        ) {
            self.peripheral = peripheral
            self.descriptor = descriptor
            self.central = central
            super.init()

            // Monitor for disconnections
            let peripheralId = peripheral.identifier
            disconnectionObserver = NotificationCenter.default.addObserver(
                forName: .bluetoothPeripheralDisconnected,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self = self,
                    let disconnectedId = notification.object as? UUID,
                    disconnectedId == peripheralId
                else { return }
                Task { @MainActor in
                    await self.handleDisconnection()
                }
            }
        }

        deinit {
            // Use MainActor.assumeIsolated for cleanup in deinit
            Task { @MainActor [disconnectionObserver] in
                if let observer = disconnectionObserver {
                    NotificationCenter.default.removeObserver(observer)
                }
            }
        }

        var mtu: Int {
            peripheral.maximumWriteValueLength(for: .withResponse)
        }

        var isConnected: Bool {
            peripheral.state == .connected
        }

        func prepare() async throws {
            Logger.bluetooth.info(
                "🔧 CoreBluetoothLink: Preparing link for \(self.peripheral.name ?? "unnamed")")
            peripheral.delegate = self
            Logger.bluetooth.info("🔧 CoreBluetoothLink: Discovering services...")
            try await discoverServices()
            Logger.bluetooth.info("🔧 CoreBluetoothLink: Discovering characteristics...")
            try await discoverCharacteristics()
            Logger.bluetooth.info("✅ CoreBluetoothLink: Link preparation complete")
        }

        func read(from characteristic: BluetoothCharacteristic) async throws -> Data {
            let cbCharacteristic = try await cbCharacteristic(for: characteristic)
            return try await withCheckedThrowingContinuation { continuation in
                readContinuations[characteristic] = continuation
                peripheral.readValue(for: cbCharacteristic)
            }
        }

        func enableNotifications(for characteristic: BluetoothCharacteristic) async throws {
            Logger.bluetooth.info(
                "🔔 CoreBluetoothLink: Enabling notifications for \(characteristic.characteristic)"
            )
            let cbCharacteristic = try await cbCharacteristic(for: characteristic)

            // If already notifying, we're done
            if cbCharacteristic.isNotifying {
                Logger.bluetooth.info("🔔 CoreBluetoothLink: Notifications already enabled")
                return
            }

            try await withCheckedThrowingContinuation { continuation in
                notificationStateContinuations[characteristic] = continuation
                peripheral.setNotifyValue(true, for: cbCharacteristic)
            }

            Logger.bluetooth.info("✅ CoreBluetoothLink: Notifications enabled successfully")
        }

        func write(
            _ data: Data, to characteristic: BluetoothCharacteristic, type: BluetoothWriteType
        ) async throws {
            let cbCharacteristic = try await cbCharacteristic(for: characteristic)

            // Determine write type based on characteristic properties
            let actualType: CBCharacteristicWriteType
            if cbCharacteristic.properties.contains(.write) {
                actualType = type == .withResponse ? .withResponse : .withoutResponse
            } else if cbCharacteristic.properties.contains(.writeWithoutResponse) {
                actualType = .withoutResponse
            } else {
                throw BluetoothTransportError.missingCharacteristic(characteristic)
            }

            if actualType == .withoutResponse {
                // For withoutResponse, write immediately
                peripheral.writeValue(data, for: cbCharacteristic, type: .withoutResponse)
                return
            }

            try await withCheckedThrowingContinuation { continuation in
                writeContinuations[characteristic] = continuation
                peripheral.writeValue(data, for: cbCharacteristic, type: .withResponse)
            }
        }

        func notifications(for characteristic: BluetoothCharacteristic) -> AsyncThrowingStream<
            Data, Error
        > {
            AsyncThrowingStream { continuation in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        let cbCharacteristic = try await self.cbCharacteristic(for: characteristic)
                        notificationContinuations[characteristic]?.finish()
                        notificationContinuations[characteristic] = continuation
                        peripheral.setNotifyValue(true, for: cbCharacteristic)
                    } catch {
                        _ = continuation.yield(with: .failure(error))
                        continuation.finish()
                    }
                }
            }
        }

        func getDiscoveredCharacteristics(for service: BluetoothUUID) async throws
            -> [BluetoothCharacteristic]
        {
            Logger.bluetooth.info(
                "🔍 CoreBluetoothLink: Getting discovered characteristics for service \(service)")

            // Get all characteristics for this service
            let allChars = characteristicMap.filter { $0.key.service == service }
            Logger.bluetooth.info("🔍 CoreBluetoothLink: Found \(allChars.count) characteristic(s)")
            // Log properties of each characteristic to help identify them
            for (bluetoothChar, cbChar) in allChars {
                var props: [String] = []
                if cbChar.properties.contains(.read) { props.append("read") }
                if cbChar.properties.contains(.write) { props.append("write") }
                if cbChar.properties.contains(.writeWithoutResponse) {
                    props.append("writeWithoutResponse")
                }
                if cbChar.properties.contains(.notify) { props.append("notify") }
                if cbChar.properties.contains(.indicate) { props.append("indicate") }
                Logger.bluetooth.info(
                    "  📍 Characteristic \(bluetoothChar.characteristic): [\(props.joined(separator: ", "))]"
                )
            }

            return Array(allChars.keys)
        }

        func getWriteCharacteristic(for service: BluetoothUUID) async throws
            -> BluetoothCharacteristic?
        {
            let allChars = characteristicMap.filter { $0.key.service == service }
            return allChars.first(where: { (_, cbChar) in
                cbChar.properties.contains(.write)
                    || cbChar.properties.contains(.writeWithoutResponse)
            })?.key
        }

        func getNotifyCharacteristic(for service: BluetoothUUID) async throws
            -> BluetoothCharacteristic?
        {
            let allChars = characteristicMap.filter { $0.key.service == service }
            return allChars.first(where: { (_, cbChar) in
                cbChar.properties.contains(.notify) || cbChar.properties.contains(.indicate)
            })?.key
        }

        func getWriteType(for characteristic: BluetoothCharacteristic) async throws
            -> BluetoothWriteType
        {
            let cbCharacteristic = try await cbCharacteristic(for: characteristic)

            // If characteristic supports .write, prefer .withResponse for reliability
            // Otherwise use .withoutResponse
            if cbCharacteristic.properties.contains(.write) {
                return .withResponse
            } else if cbCharacteristic.properties.contains(.writeWithoutResponse) {
                return .withoutResponse
            } else {
                throw BluetoothTransportError.missingCharacteristic(characteristic)
            }
        }

        func close() async {
            guard !isClosed else { return }
            isClosed = true

            if let observer = disconnectionObserver {
                NotificationCenter.default.removeObserver(observer)
                disconnectionObserver = nil
            }

            notificationContinuations.values.forEach { $0.finish() }
            notificationContinuations.removeAll()
            readContinuations.values.forEach { $0.resume(throwing: BluetoothTransportError.closed) }
            readContinuations.removeAll()
            writeContinuations.values.forEach {
                $0.resume(throwing: BluetoothTransportError.closed)
            }
            writeContinuations.removeAll()
            if let central {
                central.cancelPeripheralConnection(peripheral)
            }
        }

        private func handleDisconnection() async {
            guard !isClosed else { return }
            Logger.bluetooth.error("❌ CoreBluetoothLink: Handling disconnection event")
            isClosed = true

            let error = BluetoothTransportError.disconnected(nil)

            // Fail all pending operations
            serviceContinuation?.resume(throwing: error)
            serviceContinuation = nil

            characteristicContinuations.values.forEach { $0.resume(throwing: error) }
            characteristicContinuations.removeAll()

            readContinuations.values.forEach { $0.resume(throwing: error) }
            readContinuations.removeAll()

            writeContinuations.values.forEach { $0.resume(throwing: error) }
            writeContinuations.removeAll()

            notificationStateContinuations.values.forEach { $0.resume(throwing: error) }
            notificationStateContinuations.removeAll()

            notificationContinuations.values.forEach {
                _ = $0.yield(with: .failure(error))
                $0.finish()
            }
            notificationContinuations.removeAll()
        }

        private func cbCharacteristic(for characteristic: BluetoothCharacteristic) async throws
            -> CBCharacteristic
        {
            if let cached = characteristicMap[characteristic] {
                return cached
            }
            throw BluetoothTransportError.missingCharacteristic(characteristic)
        }

        private func discoverServices() async throws {
            try await withCheckedThrowingContinuation { continuation in
                serviceContinuation = continuation
                peripheral.discoverServices(descriptor.serviceUUIDs.map { $0.cbUUID })
            }
        }

        private func discoverCharacteristics() async throws {
            guard let services = peripheral.services else { return }
            for service in services {
                guard descriptor.serviceUUIDs.contains(BluetoothUUID(service.uuid.uuidString))
                else { continue }
                try await withCheckedThrowingContinuation { continuation in
                    characteristicContinuations[service.uuid] = continuation
                    peripheral.discoverCharacteristics(nil, for: service)
                }
            }
        }

        private func key(for characteristic: CBCharacteristic) -> BluetoothCharacteristic {
            let serviceUUID = BluetoothUUID(characteristic.service?.uuid.uuidString ?? "")
            let charUUID = BluetoothUUID(characteristic.uuid.uuidString)
            return BluetoothCharacteristic(service: serviceUUID, characteristic: charUUID)
        }
    }

    extension CoreBluetoothLink: @MainActor CBPeripheralDelegate {
        func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
            guard let continuation = serviceContinuation else { return }
            serviceContinuation = nil
            if let error {
                continuation.resume(throwing: error)
                return
            }

            continuation.resume()
        }

        func peripheral(
            _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
            error: Error?
        ) {
            guard let continuation = characteristicContinuations.removeValue(forKey: service.uuid)
            else { return }
            if let error {
                continuation.resume(throwing: error)
                return
            }

            for characteristic in service.characteristics ?? [] {
                let key = key(for: characteristic)
                characteristicMap[key] = characteristic
            }

            continuation.resume()
        }

        func peripheral(
            _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
            error: Error?
        ) {
            let key = key(for: characteristic)

            if let error {
                if let continuation = readContinuations.removeValue(forKey: key) {
                    continuation.resume(throwing: error)
                }
                if let notification = notificationContinuations[key] {
                    _ = notification.yield(with: .failure(error))
                    notification.finish()
                }
                return
            }

            guard let value = characteristic.value else {
                return
            }

            if let continuation = readContinuations.removeValue(forKey: key) {
                continuation.resume(returning: value)
            }

            if let notification = notificationContinuations[key] {
                notification.yield(value)
            }
        }

        func peripheral(
            _ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
            error: Error?
        ) {
            let key = key(for: characteristic)
            guard let continuation = writeContinuations.removeValue(forKey: key) else { return }
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }

        func peripheral(
            _ peripheral: CBPeripheral,
            didUpdateNotificationStateFor characteristic: CBCharacteristic,
            error: Error?
        ) {
            let key = key(for: characteristic)
            guard let continuation = notificationStateContinuations.removeValue(forKey: key) else {
                return
            }

            if let error {
                continuation.resume(throwing: error)
            } else if characteristic.isNotifying {
                continuation.resume()
            } else {
                continuation.resume(throwing: BluetoothTransportError.missingCharacteristic(key))
            }
        }
    }

#endif
