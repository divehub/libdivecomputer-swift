import Foundation

#if canImport(CoreBluetooth)
    import CoreBluetooth

    @MainActor
    public final class CoreBluetoothTransport: NSObject, BluetoothTransport {
        private var central: CBCentralManager!
        private var scanContinuation: AsyncThrowingStream<BluetoothDiscovery, Error>.Continuation?
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
                    print("🔍 Starting BLE scan for services: \(services.map { $0.uuidString })")
                    print("🔍 Scanning for \(descriptors.count) descriptor(s)")
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
            print("🔌 CoreBluetoothTransport: Connecting to \(discovery.id)")
            try await waitUntilReady()
            let peripheral: CBPeripheral?
            if let cached = discoveredPeripherals[discovery.id] {
                print("🔌 CoreBluetoothTransport: Using cached peripheral")
                peripheral = cached
            } else {
                print("🔌 CoreBluetoothTransport: Retrieving peripheral by identifier")
                peripheral = central.retrievePeripherals(withIdentifiers: [discovery.id]).first
            }

            guard let target = peripheral else {
                print("❌ CoreBluetoothTransport: Peripheral not found")
                throw BluetoothTransportError.peripheralUnavailable
            }

            peripheralDescriptors[target.identifier] = discovery.descriptor
            print(
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
            print(
                "📶 Bluetooth state: \(central.state.rawValue) - \(stateDescription(central.state))")
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
                continuation.resume(throwing: BluetoothTransportError.unsupported)
            }

            readinessContinuation = nil
        }

        public func centralManager(
            _ central: CBCentralManager,
            didDiscover peripheral: CBPeripheral,
            advertisementData: [String: Any],
            rssi RSSI: NSNumber
        ) {
            print(
                "📱 Discovered peripheral: \(peripheral.name ?? "Unknown") (\(peripheral.identifier))"
            )
            print("📱 Advertisement data: \(advertisementData)")
            guard let descriptor = matchDescriptor(for: advertisementData) else {
                print("⚠️ No matching descriptor for this peripheral")
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
            print(
                "✅ CoreBluetoothTransport: Connected to \(peripheral.name ?? "unnamed") (\(peripheral.identifier))"
            )
            guard let descriptor = peripheralDescriptors[peripheral.identifier],
                let continuation = connectContinuations.removeValue(forKey: peripheral.identifier)
            else {
                print("⚠️ CoreBluetoothTransport: No continuation found for peripheral")
                return
            }

            let link = CoreBluetoothLink(
                peripheral: peripheral, descriptor: descriptor, central: central)
            Task { @MainActor in
                do {
                    try await link.prepare()
                    print("✅ CoreBluetoothTransport: Link prepared, resuming continuation")
                    continuation.resume(returning: link)
                } catch {
                    print("❌ CoreBluetoothTransport: Link preparation failed: \(error)")
                    continuation.resume(throwing: error)
                }
            }
        }

        public func centralManager(
            _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?
        ) {
            print(
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
            if let continuation = connectContinuations.removeValue(forKey: peripheral.identifier) {
                continuation.resume(throwing: error ?? BluetoothTransportError.closed)
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

        init(
            peripheral: CBPeripheral, descriptor: DiveComputerDescriptor, central: CBCentralManager
        ) {
            self.peripheral = peripheral
            self.descriptor = descriptor
            self.central = central
            super.init()
        }

        var mtu: Int {
            peripheral.maximumWriteValueLength(for: .withResponse)
        }

        func prepare() async throws {
            print("🔧 CoreBluetoothLink: Preparing link for \(peripheral.name ?? "unnamed")")
            peripheral.delegate = self
            print("🔧 CoreBluetoothLink: Discovering services...")
            try await discoverServices()
            print("🔧 CoreBluetoothLink: Discovering characteristics...")
            try await discoverCharacteristics()
            print("✅ CoreBluetoothLink: Link preparation complete")
        }

        func read(from characteristic: BluetoothCharacteristic) async throws -> Data {
            let cbCharacteristic = try await cbCharacteristic(for: characteristic)
            return try await withCheckedThrowingContinuation { continuation in
                readContinuations[characteristic] = continuation
                peripheral.readValue(for: cbCharacteristic)
            }
        }

        func enableNotifications(for characteristic: BluetoothCharacteristic) async throws {
            print(
                "🔔 CoreBluetoothLink: Enabling notifications for \(characteristic.characteristic)"
            )
            let cbCharacteristic = try await cbCharacteristic(for: characteristic)

            // If already notifying, we're done
            if cbCharacteristic.isNotifying {
                print("🔔 CoreBluetoothLink: Notifications already enabled")
                return
            }

            try await withCheckedThrowingContinuation { continuation in
                notificationStateContinuations[characteristic] = continuation
                peripheral.setNotifyValue(true, for: cbCharacteristic)
            }

            print("✅ CoreBluetoothLink: Notifications enabled successfully")
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
            print("🔍 CoreBluetoothLink: Getting discovered characteristics for service \(service)")

            // Get all characteristics for this service
            let allChars = characteristicMap.filter { $0.key.service == service }
            print("🔍 CoreBluetoothLink: Found \(allChars.count) characteristic(s)")

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
                print(
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
