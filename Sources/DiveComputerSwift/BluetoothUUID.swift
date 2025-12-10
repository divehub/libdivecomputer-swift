import Foundation
#if canImport(CoreBluetooth)
import CoreBluetooth
#endif

public struct BluetoothUUID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue.uppercased()
    }

    public var description: String { rawValue }

    #if canImport(CoreBluetooth)
    var cbUUID: CBUUID { CBUUID(string: rawValue) }
    #endif
}

public struct BluetoothCharacteristic: Hashable, Codable, Sendable {
    public let service: BluetoothUUID
    public let characteristic: BluetoothUUID

    public init(service: BluetoothUUID, characteristic: BluetoothUUID) {
        self.service = service
        self.characteristic = characteristic
    }
}

public enum CharacteristicRole: String, Hashable, Codable, Sendable {
    case command
    case notification
    case telemetry
    case configuration
    case logStream
}

public struct BluetoothServiceConfiguration: Hashable, Codable, Sendable {
    public let service: BluetoothUUID
    private let characteristicMap: [CharacteristicRole: BluetoothUUID]

    public init(service: BluetoothUUID, characteristics: [CharacteristicRole: BluetoothUUID]) {
        self.service = service
        self.characteristicMap = characteristics
    }

    public func characteristic(for role: CharacteristicRole) -> BluetoothCharacteristic? {
        guard let characteristicUUID = characteristicMap[role] else { return nil }
        return BluetoothCharacteristic(service: service, characteristic: characteristicUUID)
    }

    public var characteristicRoles: [CharacteristicRole] {
        Array(characteristicMap.keys)
    }

    #if canImport(CoreBluetooth)
    var cbService: CBUUID { service.cbUUID }
    #endif
}
