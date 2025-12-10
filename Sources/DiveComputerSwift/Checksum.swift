import Foundation

public enum Checksum {
    public static func addUInt4(_ data: Data, initial: UInt8 = 0) -> UInt8 {
        var crc = initial
        for byte in data {
            crc &+= (byte & 0xF0) >> 4
            crc &+= byte & 0x0F
        }
        return crc
    }

    public static func addUInt8(_ data: Data, initial: UInt8 = 0) -> UInt8 {
        var crc = initial
        for byte in data {
            crc &+= byte
        }
        return crc
    }

    public static func addUInt16(_ data: Data, initial: UInt16 = 0) -> UInt16 {
        var crc = initial
        for byte in data {
            crc &+= UInt16(byte)
        }
        return crc
    }

    public static func xorUInt8(_ data: Data, initial: UInt8 = 0) -> UInt8 {
        var crc = initial
        for byte in data {
            crc ^= byte
        }
        return crc
    }

    public static func crc8(_ data: Data, initial: UInt8 = 0, xorOut: UInt8 = 0) -> UInt8 {
        crc(
            data: data,
            width: 8,
            polynomial: 0x07,
            initial: initial,
            xorOut: xorOut,
            reflect: false
        )
    }

    public static func crc16CCITT(_ data: Data, initial: UInt16 = 0, xorOut: UInt16 = 0) -> UInt16 {
        crc(
            data: data,
            width: 16,
            polynomial: 0x1021,
            initial: initial,
            xorOut: xorOut,
            reflect: false
        )
    }

    public static func crc16rCCITT(_ data: Data, initial: UInt16 = 0, xorOut: UInt16 = 0) -> UInt16 {
        crc(
            data: data,
            width: 16,
            polynomial: 0x8408,
            initial: initial,
            xorOut: xorOut,
            reflect: true
        )
    }

    public static func crc16ANSI(_ data: Data, initial: UInt16 = 0, xorOut: UInt16 = 0) -> UInt16 {
        crc(
            data: data,
            width: 16,
            polynomial: 0x8005,
            initial: initial,
            xorOut: xorOut,
            reflect: false
        )
    }

    public static func crc16rANSI(_ data: Data, initial: UInt16 = 0, xorOut: UInt16 = 0) -> UInt16 {
        crc(
            data: data,
            width: 16,
            polynomial: 0xA001,
            initial: initial,
            xorOut: xorOut,
            reflect: true
        )
    }

    public static func crc32r(_ data: Data) -> UInt32 {
        crc(
            data: data,
            width: 32,
            polynomial: 0xEDB88320,
            initial: 0xffffffff,
            xorOut: 0xffffffff,
            reflect: true
        )
    }

    public static func crc32(_ data: Data) -> UInt32 {
        crc(
            data: data,
            width: 32,
            polynomial: 0x04C11DB7,
            initial: 0xffffffff,
            xorOut: 0xffffffff,
            reflect: false
        )
    }

    private static func crc<T: FixedWidthInteger & UnsignedInteger>(
        data: Data,
        width: Int,
        polynomial: T,
        initial: T,
        xorOut: T,
        reflect: Bool
    ) -> T {
        let mask = width >= T.bitWidth ? ~T.zero : ((T(1) << T(width)) &- 1)
        let topBit = T(1) << T(width - 1)
        var crc = initial & mask

        for byte in data {
            if reflect {
                crc ^= T(byte)
                for _ in 0..<8 {
                    let lsbSet = (crc & 0x01) != 0
                    crc = (crc >> 1) & mask
                    if lsbSet {
                        crc ^= polynomial
                    }
                }
            } else {
                crc ^= T(byte) << T(width - 8)
                for _ in 0..<8 {
                    let msbSet = (crc & topBit) != 0
                    crc = (crc << 1) & mask
                    if msbSet {
                        crc ^= polynomial
                    }
                }
            }
        }

        return (crc ^ xorOut) & mask
    }
}
