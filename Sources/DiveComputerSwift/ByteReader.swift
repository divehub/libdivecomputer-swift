import Foundation

public enum ByteReaderError: Error {
    case outOfBounds(requested: Int, available: Int)
}

public struct ByteReader: Sendable {
    private let data: Data
    private var offset: Int = 0

    public init(data: Data) {
        self.data = data
    }

    public var remaining: Int {
        data.count - offset
    }

    public mutating func skip(_ count: Int) throws {
        guard offset + count <= data.count else {
            throw ByteReaderError.outOfBounds(requested: count, available: remaining)
        }
        offset += count
    }

    public mutating func readUInt8() throws -> UInt8 {
        try readInteger(endian: .little) as UInt8
    }

    public mutating func readInt8() throws -> Int8 {
        Int8(bitPattern: try readUInt8())
    }

    public mutating func readUInt16(endian: Endianness = .little) throws -> UInt16 {
        try readInteger(endian: endian)
    }

    public mutating func readInt16(endian: Endianness = .little) throws -> Int16 {
        Int16(bitPattern: try readUInt16(endian: endian))
    }

    public mutating func readUInt32(endian: Endianness = .little) throws -> UInt32 {
        try readInteger(endian: endian)
    }

    public mutating func readInt32(endian: Endianness = .little) throws -> Int32 {
        Int32(bitPattern: try readUInt32(endian: endian))
    }

    public mutating func readBytes(count: Int) throws -> Data {
        guard offset + count <= data.count else {
            throw ByteReaderError.outOfBounds(requested: count, available: remaining)
        }
        let slice = data[offset..<offset + count]
        offset += count
        return Data(slice)
    }

    public enum Endianness {
        case little
        case big
    }

    private mutating func readInteger<T: FixedWidthInteger>(endian: Endianness) throws -> T {
        let size = MemoryLayout<T>.size
        guard offset + size <= data.count else {
            throw ByteReaderError.outOfBounds(requested: size, available: remaining)
        }

        let slice = data[offset..<(offset + size)]
        offset += size

        var value: T = 0
        switch endian {
        case .little:
            for (i, byte) in slice.enumerated() {
                value |= T(byte) << T(i * 8)
            }
        case .big:
            for (i, byte) in slice.enumerated() {
                value |= T(byte) << T((size - 1 - i) * 8)
            }
        }
        return value
    }
}
