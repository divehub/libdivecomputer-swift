import Foundation
import os

public enum DiveComputerManagerError: Error {
    case unknownDriver(id: String)
}

@MainActor
public final class DiveComputerManager {
    private var driversByServiceUUID: [BluetoothUUID: any DiveComputerDriver] = [:]
    private let transport: BluetoothTransport

    public init(transport: BluetoothTransport) {
        self.transport = transport
    }
    
    public var bluetoothState: AsyncStream<BluetoothState> {
        transport.bluetoothState
    }

    public func register(driver: any DiveComputerDriver) {
        for serviceUUID in driver.descriptor.serviceUUIDs {
            driversByServiceUUID[serviceUUID] = driver
        }
    }

    public var supportedDescriptors: [DiveComputerDescriptor] {
        Array(Set(driversByServiceUUID.values.map(\.descriptor)))
    }

    public func scan(timeout: Duration = .seconds(10)) -> AsyncThrowingStream<
        BluetoothDiscovery, Error
    > {
        transport.scan(descriptors: supportedDescriptors, timeout: timeout)
    }

    public func stopScan() {
        transport.stopScan()
    }

    public func connect(to discovery: BluetoothDiscovery) async throws -> DiveComputerSession {
        Logger.bluetooth.info(
            "🔌 DiveComputerManager: Starting connection to \(discovery.name ?? discovery.descriptor.product)"
        )
        let serviceUUIDs = discovery.descriptor.serviceUUIDs
        guard let driver = serviceUUIDs.compactMap({ driversByServiceUUID[$0] }).first else {
            let serviceUUIDsDescription = serviceUUIDs.map(\.rawValue).joined(separator: ", ")
            Logger.bluetooth.error(
                "❌ DiveComputerManager: No driver found for service UUID(s): \(serviceUUIDsDescription)")
            throw DiveComputerManagerError.unknownDriver(
                id: serviceUUIDs.first?.rawValue ?? discovery.descriptor.id
            )
        }
        Logger.bluetooth.info("🔌 DiveComputerManager: Found driver, connecting to transport...")
        let link = try await transport.connect(discovery)
        Logger.bluetooth.info(
            "✅ DiveComputerManager: Transport connected, opening driver session...")
        let session = try await driver.open(link: link)
        Logger.bluetooth.info("✅ DiveComputerManager: Driver session opened successfully")
        return DiveComputerSession(
            descriptor: discovery.descriptor,
            link: link,
            driverSession: session
        )
    }
}
