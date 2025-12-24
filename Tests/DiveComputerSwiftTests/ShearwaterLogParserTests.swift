import XCTest
@testable import DiveComputerSwift

final class ShearwaterLogParserTests: XCTestCase {
    func testTericTimezoneOffsetParsed() {
        let data = makeLogData(isTeric: true, logVersion: 9, utcOffsetMinutes: 480, dstHours: 1)
        let parsed = ShearwaterLogParser.parse(data: data)

        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.timeZoneOffset, 480 * 60 + 3600)
    }

    func testNonTericTimezoneOffsetNil() {
        let data = makeLogData(isTeric: false, logVersion: 9, utcOffsetMinutes: 480, dstHours: 1)
        let parsed = ShearwaterLogParser.parse(data: data)

        XCTAssertNotNil(parsed)
        XCTAssertNil(parsed?.timeZoneOffset)
    }

    private func makeLogData(isTeric: Bool, logVersion: UInt8, utcOffsetMinutes: Int32, dstHours: UInt8) -> Data {
        var blocks: [[UInt8]] = []

        var opening0 = makeBlock(type: 0x10)
        writeUInt32BE(1_700_000_000, at: 12, in: &opening0)
        opening0[4] = 30
        opening0[5] = 85
        blocks.append(opening0)

        var opening4 = makeBlock(type: 0x14)
        opening4[1] = 6
        opening4[16] = logVersion
        blocks.append(opening4)

        var opening5 = makeBlock(type: 0x15)
        writeInt32BE(utcOffsetMinutes, at: 26, in: &opening5)
        opening5[30] = dstHours
        blocks.append(opening5)

        var sample = makeBlock(type: 0x01)
        writeUInt16BE(100, at: 1, in: &sample)
        sample[12] = 0x10
        blocks.append(sample)

        var final = makeBlock(type: 0xFF)
        final[13] = isTeric ? 8 : 0
        blocks.append(final)

        return Data(blocks.flatMap { $0 })
    }

    private func makeBlock(type: UInt8) -> [UInt8] {
        var block = [UInt8](repeating: 0, count: 32)
        block[0] = type
        return block
    }

    private func writeUInt16BE(_ value: UInt16, at offset: Int, in block: inout [UInt8]) {
        block[offset] = UInt8((value >> 8) & 0xFF)
        block[offset + 1] = UInt8(value & 0xFF)
    }

    private func writeUInt32BE(_ value: UInt32, at offset: Int, in block: inout [UInt8]) {
        block[offset] = UInt8((value >> 24) & 0xFF)
        block[offset + 1] = UInt8((value >> 16) & 0xFF)
        block[offset + 2] = UInt8((value >> 8) & 0xFF)
        block[offset + 3] = UInt8(value & 0xFF)
    }

    private func writeInt32BE(_ value: Int32, at offset: Int, in block: inout [UInt8]) {
        writeUInt32BE(UInt32(bitPattern: value), at: offset, in: &block)
    }
}
