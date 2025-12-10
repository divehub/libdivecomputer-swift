import Foundation

public enum BluetoothTransportError: Error {
    case poweredOff
    case unauthorized
    case unsupported
    case peripheralUnavailable
    case timedOut
    case missingCharacteristic(BluetoothCharacteristic)
    case closed
    case underlying(Error)
}

public enum BluetoothWriteType: Sendable {
    case withResponse
    case withoutResponse
}

@MainActor
public struct BluetoothDiscovery: Identifiable, Sendable {
    public let id: UUID
    public let descriptor: DiveComputerDescriptor
    public let name: String?
    public let rssi: Int
    public let advertisedServices: [BluetoothUUID]

    public init(
        id: UUID,
        descriptor: DiveComputerDescriptor,
        name: String?,
        rssi: Int,
        advertisedServices: [BluetoothUUID]
    ) {
        self.id = id
        self.descriptor = descriptor
        self.name = name
        self.rssi = rssi
        self.advertisedServices = advertisedServices
    }
}

@MainActor
public protocol BluetoothLink: AnyObject {
    var descriptor: DiveComputerDescriptor { get }
    var mtu: Int { get }
    func read(from characteristic: BluetoothCharacteristic) async throws -> Data
    func write(_ data: Data, to characteristic: BluetoothCharacteristic, type: BluetoothWriteType)
        async throws
    func enableNotifications(for characteristic: BluetoothCharacteristic) async throws
    func getWriteType(for characteristic: BluetoothCharacteristic) async throws
        -> BluetoothWriteType
    func notifications(for characteristic: BluetoothCharacteristic) -> AsyncThrowingStream<
        Data, Error
    >
    func getDiscoveredCharacteristics(for service: BluetoothUUID) async throws
        -> [BluetoothCharacteristic]
    func getWriteCharacteristic(for service: BluetoothUUID) async throws -> BluetoothCharacteristic?
    func getNotifyCharacteristic(for service: BluetoothUUID) async throws
        -> BluetoothCharacteristic?
    func close() async
}

@MainActor
public protocol BluetoothTransport: AnyObject {
    func scan(descriptors: [DiveComputerDescriptor], timeout: Duration) -> AsyncThrowingStream<
        BluetoothDiscovery, Error
    >
    func stopScan()
    func connect(_ discovery: BluetoothDiscovery) async throws -> BluetoothLink
}
