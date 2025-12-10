import Foundation

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
        print(
            "🔌 DiveComputerManager: Starting connection to \(discovery.name ?? discovery.descriptor.product)"
        )
        guard let driver = drivers[discovery.descriptor.id] else {
            print("❌ DiveComputerManager: No driver found for \(discovery.descriptor.id)")
            throw DiveComputerManagerError.unknownDriver(id: discovery.descriptor.id)
        }
        print("🔌 DiveComputerManager: Found driver, connecting to transport...")
        let link = try await transport.connect(discovery)
        print("✅ DiveComputerManager: Transport connected, opening driver session...")
        let session = try await driver.open(link: link)
        print("✅ DiveComputerManager: Driver session opened successfully")
        return DiveComputerSession(
            descriptor: discovery.descriptor,
            link: link,
            driverSession: session
        )
    }
}
