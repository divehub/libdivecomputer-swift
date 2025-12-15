import Foundation
import os

public enum DiveComputerManagerError: Error {
    case unknownDriver(id: String)
}

@MainActor
public final class DiveComputerManager {
    private var drivers: [String: any DiveComputerDriver] = [:]
    private let transport: BluetoothTransport

    public init(transport: BluetoothTransport) {
        self.transport = transport
    }
    
    public var bluetoothState: AsyncStream<BluetoothState> {
        transport.bluetoothState
    }

    public func register(driver: any DiveComputerDriver) {
        drivers[driver.descriptor.id] = driver
    }

    public var supportedDescriptors: [DiveComputerDescriptor] {
        Array(drivers.values).map(\.descriptor)
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
        guard let driver = drivers[discovery.descriptor.id] else {
            Logger.bluetooth.error(
                "❌ DiveComputerManager: No driver found for \(discovery.descriptor.id)")
            throw DiveComputerManagerError.unknownDriver(id: discovery.descriptor.id)
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
