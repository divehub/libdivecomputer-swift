import Foundation

public enum DiveComputerCapability: String, Hashable, Codable, Sendable {
    case logDownload
    case liveTelemetry
    case gasConfiguration
    case firmwareInfo
}

public struct DiveComputerDescriptor: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let vendor: String
    public let product: String
    public let capabilities: Set<DiveComputerCapability>
    public let services: [BluetoothServiceConfiguration]
    public let maximumMTU: Int?

    public init(
        id: String? = nil,
        vendor: String,
        product: String,
        capabilities: Set<DiveComputerCapability>,
        services: [BluetoothServiceConfiguration],
        maximumMTU: Int? = nil
    ) {
        self.vendor = vendor
        self.product = product
        self.capabilities = capabilities
        self.services = services
        self.maximumMTU = maximumMTU
        if let explicitID = id {
            self.id = explicitID
        } else {
            self.id = "\(vendor)-\(product)"
                .lowercased()
                .replacingOccurrences(of: " ", with: "-")
        }
    }

    public var primaryService: BluetoothUUID? {
        services.first?.service
    }

    public var serviceUUIDs: [BluetoothUUID] {
        services.map(\.service)
    }

    public func characteristic(for role: CharacteristicRole) -> BluetoothCharacteristic? {
        for service in services {
            if let characteristic = service.characteristic(for: role) {
                return characteristic
            }
        }
        return nil
    }

    public func usesService(uuid: BluetoothUUID) -> Bool {
        services.contains { $0.service == uuid }
    }
}
