import Foundation

public enum ShearwaterError: Error, LocalizedError {
    case invalidResponse(expected: UInt8, got: UInt8)
    case invalidPacketHeader
    case invalidPacketLength(expected: Int, got: Int)
    case packetTooShort(minimum: Int, actual: Int)
    case unexpectedRDBIResponse(id: UInt16)
    case invalidRDBIPayloadLength(expected: Int, got: Int)
    case unexpectedInitResponse(expected: UInt8, got: UInt8)
    case unexpectedBlockResponse(expectedIndex: UInt8, gotIndex: UInt8)
    case unexpectedQuitResponse
    case invalidLRELength
    case unsupportedDiveMode(UInt8)
    case invalidManifestHeader(UInt16)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .invalidResponse(let expected, let got):
            return
                "Invalid response: expected 0x\(String(expected, radix: 16, uppercase: true)), got 0x\(String(got, radix: 16, uppercase: true))"
        case .invalidPacketHeader:
            return "Invalid packet header"
        case .invalidPacketLength(let expected, let got):
            return "Invalid packet length: expected \(expected), got \(got)"
        case .packetTooShort(let minimum, let actual):
            return "Packet too short: minimum \(minimum) bytes, got \(actual)"
        case .unexpectedRDBIResponse(let id):
            return "Unexpected RDBI response for ID 0x\(String(id, radix: 16, uppercase: true))"
        case .invalidRDBIPayloadLength(let expected, let got):
            return "Invalid RDBI payload length: expected \(expected), got \(got)"
        case .unexpectedInitResponse(let expected, let got):
            return
                "Unexpected init response: expected 0x\(String(expected, radix: 16, uppercase: true)), got 0x\(String(got, radix: 16, uppercase: true))"
        case .unexpectedBlockResponse(let expectedIndex, let gotIndex):
            return "Unexpected block response: expected index \(expectedIndex), got \(gotIndex)"
        case .unexpectedQuitResponse:
            return "Unexpected quit response"
        case .invalidLRELength:
            return "Invalid LRE compressed data length (must be multiple of 9 bits)"
        case .unsupportedDiveMode(let mode):
            return "Unsupported dive mode: 0x\(String(mode, radix: 16, uppercase: true))"
        case .invalidManifestHeader(let header):
            return "Invalid manifest header: 0x\(String(header, radix: 16, uppercase: true))"
        case .timeout:
            return "Response timeout - no data received from device"
        }
    }
}
