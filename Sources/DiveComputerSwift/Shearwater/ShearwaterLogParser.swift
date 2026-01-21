import Foundation

/// A parser for Shearwater dive logs in the Petrel Native Format (PNF).
/// This format is used by Petrel, Petrel 2, Petrel 3, Perdix, Perdix 2, Teric, Peregrine, etc.
/// Legacy "Predator" format (128-byte blocks) is NOT supported.
public struct ShearwaterLogParser {

    public struct ParsedDive: Sendable {
        public let startTimeUTC: Date
        public let startTimeLocal: Date
        public let duration: Duration
        public let maxDepth: Double
        public let avgDepth: Double
        public let surfacePressure: Double?  // Bar
        public let samples: [DiveSample]
        public let gasMixes: [GasMix]
        public let tanks: [DiveTank]
        public let decoModel: String?
        public let gradientFactorLow: Int?
        public let gradientFactorHigh: Int?
        public let diveMode: DiveMode?
        public let waterDensity: Double?
        public let fingerprint: Data?
    }

    // --- Internal Helpers ---

    private struct DataReader {
        let data: Data

        func u8(at offset: Int) -> UInt8? {
            guard offset < data.count else { return nil }
            return data[offset]
        }

        func u16be(at offset: Int) -> UInt16? {
            guard offset + 1 < data.count else { return nil }
            return (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
        }

        func u24be(at offset: Int) -> UInt32? {
            guard offset + 2 < data.count else { return nil }
            return (UInt32(data[offset]) << 16) | (UInt32(data[offset + 1]) << 8)
                | UInt32(data[offset + 2])
        }

        func u32be(at offset: Int) -> UInt32? {
            guard offset + 3 < data.count else { return nil }
            return (UInt32(data[offset]) << 24) | (UInt32(data[offset + 1]) << 16)
                | (UInt32(data[offset + 2]) << 8) | UInt32(data[offset + 3])
        }

        func subdata(at offset: Int, length: Int) -> Data? {
            guard offset + length <= data.count else { return nil }
            return data.subdata(in: offset..<offset + length)
        }
    }

    private enum RecordType: UInt8 {
        case diveSample = 0x01
        case freediveSample = 0x02
        case aveloSample = 0x03

        case opening0 = 0x10
        case opening1 = 0x11
        case opening2 = 0x12
        case opening3 = 0x13
        case opening4 = 0x14
        case opening5 = 0x15
        case opening6 = 0x16
        case opening7 = 0x17

        case closing0 = 0x20
        case closing1 = 0x21
        case closing2 = 0x22
        case closing3 = 0x23
        case closing4 = 0x24
        case closing5 = 0x25
        case closing6 = 0x26
        case closing7 = 0x27

        case info = 0x30
        case diveSampleExt = 0xE1
        case final = 0xFF
    }

    private static let blockSize = 32

    // --- Main Parse Entry Point ---

    public static func parse(data: Data) -> ParsedDive? {
        guard data.count >= blockSize else { return nil }

        // 1. Extract Records
        let (rawSamples, rawSampleExts, openingRecords, closingRecords, finalRecord, _) =
            extractRecords(from: data)

        // 2. Parse Headers / Metadata
        let headers = parseHeaders(
            openingRecords: openingRecords, closingRecords: closingRecords, finalRecord: finalRecord
        )
        guard let startTimeLocal = headers.startTime else { return nil }
        let startTimeUTC = startTimeLocal.addingTimeInterval(-(headers.timeZoneOffset ?? 0))

        // 3. Parse Samples
        let sampleResult = parseSamples(
            rawSamples: rawSamples,
            rawSampleExts: rawSampleExts,
            startTime: startTimeUTC,
            headers: headers
        )
        let samples = sampleResult.samples
        var tanks = headers.tanks
        if !sampleResult.pressureRecordsByTankIndex.isEmpty {
            let maxIndex = sampleResult.pressureRecordsByTankIndex.keys.max() ?? -1
            if maxIndex >= 0, tanks.count <= maxIndex {
                for i in tanks.count...maxIndex {
                    tanks.append(DiveTank(name: "Tank \(i + 1)"))
                }
            }

            if tanks.isEmpty, maxIndex >= 0 {
                tanks = (0...maxIndex).map { DiveTank(name: "Tank \($0 + 1)") }
            }

            for (index, records) in sampleResult.pressureRecordsByTankIndex {
                guard !records.isEmpty else { continue }
                if index >= tanks.count {
                    tanks.append(DiveTank(name: "Tank \(index + 1)", pressureRecords: records))
                } else {
                    tanks[index].pressureRecords = records
                }

                let startPressure = records.first?.pressureBar
                let endPressure = records.last?.pressureBar
                if tanks[index].startPressureBar == nil {
                    tanks[index].startPressureBar = startPressure
                }
                if tanks[index].endPressureBar == nil {
                    tanks[index].endPressureBar = endPressure
                }
            }
        }

        guard !samples.isEmpty else { return nil }

        // 4. Calculate Stats (Fallback)
        let calcMaxDepth = samples.max(by: { $0.depthMeters < $1.depthMeters })?.depthMeters ?? 0
        let calcAvgDepth = samples.reduce(0.0) { $0 + $1.depthMeters } / Double(samples.count)
        let calcDuration = rawSamples.last?.timeOffset ?? 0

        // Prefer Closing Record stats if available
        let maxDepth = headers.maxDepth ?? calcMaxDepth
        let duration = headers.duration ?? calcDuration

        return ParsedDive(
            startTimeUTC: startTimeUTC,
            startTimeLocal: startTimeLocal,
            duration: .seconds(duration),
            maxDepth: maxDepth,
            avgDepth: calcAvgDepth,
            surfacePressure: headers.surfacePressure,
            samples: samples,
            gasMixes: headers.gasMixes,
            tanks: tanks,
            decoModel: headers.decoModel,
            gradientFactorLow: headers.gfLow,
            gradientFactorHigh: headers.gfHigh,
            diveMode: headers.diveMode,
            waterDensity: headers.waterDensity,
            fingerprint: headers.fingerprint
        )
    }

    /// Parse Shearwater PNF data and return a DiveLog with format set to .shearwater
    /// This is the preferred method for external consumers
    public static func parseToDiveLog(data: Data) -> DiveLog? {
        guard let parsed = parse(data: data) else { return nil }

        return DiveLog(
            startTimeUTC: parsed.startTimeUTC,
            startTimeLocal: parsed.startTimeLocal,
            duration: parsed.duration,
            maxDepthMeters: parsed.maxDepth,
            averageDepthMeters: parsed.avgDepth,
            waterTemperatureCelsius: nil,  // Shearwater logs don't have overall water temp
            surfacePressureBar: parsed.surfacePressure,
            samples: parsed.samples,
            gasMixes: parsed.gasMixes,
            tanks: parsed.tanks,
            decoModel: parsed.decoModel,
            gradientFactorLow: parsed.gradientFactorLow,
            gradientFactorHigh: parsed.gradientFactorHigh,
            diveMode: parsed.diveMode,
            waterDensity: parsed.waterDensity,
            fingerprint: parsed.fingerprint.map { $0.map { String(format: "%02X", $0) }.joined() },
            rawData: data,
            format: .shearwater
        )
    }

    // --- Phase 1: Record Extraction ---

    private static func extractRecords(from data: Data) -> (
        samples: [(timeOffset: TimeInterval, data: DataReader)],
        sampleExts: [(timeOffset: TimeInterval, data: DataReader)],
        opening: [RecordType: DataReader],
        closing: [RecordType: DataReader],
        final: DataReader?,
        interval: TimeInterval
    ) {
        var offset = 0
        var samples: [(TimeInterval, DataReader)] = []
        var sampleExts: [(TimeInterval, DataReader)] = []
        var opening: [RecordType: DataReader] = [:]
        var closing: [RecordType: DataReader] = [:]
        var final: DataReader? = nil

        var sampleInterval: TimeInterval = 10.0
        var currentTime: TimeInterval = 0

        while offset + blockSize <= data.count {
            let blockData = data.subdata(in: offset..<offset + blockSize)
            let reader = DataReader(data: blockData)

            if let typeByte = reader.u8(at: 0), let type = RecordType(rawValue: typeByte) {
                switch type {
                case .diveSample:
                    currentTime += sampleInterval
                    samples.append((currentTime, reader))

                case .diveSampleExt:
                    sampleExts.append((currentTime, reader))

                case .opening0, .opening1, .opening2, .opening3, .opening4, .opening5, .opening6,
                    .opening7:
                    opening[type] = reader

                    // Check Sample Interval in Opening 5
                    if type == .opening5, let intervalMs = reader.u16be(at: 23), intervalMs > 0 {
                        sampleInterval = TimeInterval(intervalMs) / 1000.0
                    }

                case .closing0, .closing1, .closing2, .closing3, .closing4, .closing5, .closing6,
                    .closing7:
                    closing[type] = reader

                case .final:
                    final = reader

                default:
                    break
                }
            }
            offset += blockSize
        }

        return (samples, sampleExts, opening, closing, final, sampleInterval)
    }

    // --- Phase 2: Header Parsing ---

    private struct Headers {
        var startTime: Date?
        var duration: Double?  // Added
        var maxDepth: Double?  // Added
        var fingerprint: Data?
        var diveMode: DiveMode?
        var isImperial: Bool
        var isTeric: Bool
        var logVersion: Int
        var aiMode: UInt8?
        var timeZoneOffset: TimeInterval?
        var decoModel: String?
        var waterDensity: Double?
        var surfacePressure: Double?
        var gfLow: Int?
        var gfHigh: Int?
        var gasMixes: [GasMix]
        var tanks: [DiveTank]
        var calibration: [Double]
    }

    private static func parseHeaders(
        openingRecords: [RecordType: DataReader], closingRecords: [RecordType: DataReader],
        finalRecord: DataReader?
    ) -> Headers {
        var h = Headers(
            startTime: nil, duration: nil, maxDepth: nil, fingerprint: nil, diveMode: nil,
            isImperial: false, isTeric: false,
            logVersion: 0, aiMode: nil, timeZoneOffset: nil, decoModel: nil,
            waterDensity: nil, surfacePressure: nil,
            gfLow: nil, gfHigh: nil, gasMixes: [], tanks: [], calibration: [0, 0, 0]
        )

        // Opening 0
        if let op0 = openingRecords[.opening0] {
            h.fingerprint = op0.subdata(at: 12, length: 4)

            if let ts = op0.u32be(at: 12), ts > 0 {
                h.startTime = Date(timeIntervalSince1970: TimeInterval(ts))
            }

            h.isImperial = (op0.u8(at: 8) == 1)

            h.gfLow = op0.u8(at: 4).map { Int($0) }
            h.gfHigh = op0.u8(at: 5).map { Int($0) }
        }

        // Closing 0 (Stats)
        if let cl0 = closingRecords[.closing0] {
            // Duration: 3 bytes at offset 6 (seconds)
            if let durSec = cl0.u24be(at: 6) {
                h.duration = Double(durSec)
            }

            // Max Depth: 2 bytes at offset 4
            if let maxRaw = cl0.u16be(at: 4) {
                var maxD = Double(maxRaw)
                if h.isImperial {
                    maxD *= 0.3048
                }
                // PNF format divides by 10.0
                maxD /= 10.0
                h.maxDepth = maxD
            }
        }

        // Opening 2 (Backup StartTime & DecoModel)
        if let op2 = openingRecords[.opening2] {
            if h.startTime == nil, let ts = op2.u32be(at: 20), ts > 0 {
                h.startTime = Date(timeIntervalSince1970: TimeInterval(ts))
            }

            if let modelByte = op2.u8(at: 18) {
                switch modelByte {
                case 0: h.decoModel = "Buhlmann ZHL-16C"
                case 1: h.decoModel = "VPM-B"
                case 2: h.decoModel = "VPM-B/GFS"
                case 3: h.decoModel = "DCIEM"
                default: h.decoModel = "Unknown (\(modelByte))"
                }
            }
        }

        // Opening 4 (Mode, Version, Gases Enabled)
        var gasesEnabled = 0x1F  // Default: First 5 gases
        if let op4 = openingRecords[.opening4] {
            h.logVersion = Int(op4.u8(at: 16) ?? 0)

            if let modeByte = op4.u8(at: 1) {
                switch modeByte {
                case 0, 5: h.diveMode = .ccr
                case 1: h.diveMode = .ocTec
                case 2: h.diveMode = .gauge
                case 3: h.diveMode = .ppo2
                case 4: h.diveMode = .semiClosed
                case 6: h.diveMode = .ocRec
                case 7: h.diveMode = .freedive
                case 12: h.diveMode = .avelo
                default: h.diveMode = .unknown
                }
            }

            if let enabledString = op4.u16be(at: 17) {
                gasesEnabled = Int(enabledString)
            }

            // AI check (Byte 28)
            if let aiMode = op4.u8(at: 28) {
                h.aiMode = aiMode
            }
        }

        // Gases (Opening 0 & 1)
        if let op0 = openingRecords[.opening0] {
            let o2s = (0..<10).map { op0.u8(at: 20 + $0) ?? 0 }
            var hes = [UInt8](repeating: 0, count: 10)

            hes[0] = op0.u8(at: 30) ?? 0
            hes[1] = op0.u8(at: 31) ?? 0

            if let op1 = openingRecords[.opening1] {
                for i in 2..<10 {
                    hes[i] = op1.u8(at: 1 + (i - 2)) ?? 0
                }
            }

            let isCCR = (h.diveMode == .ccr || h.diveMode == .semiClosed)

            for i in 0..<10 {
                let isEnabled = (gasesEnabled & (1 << i)) != 0
                let isDiluent = (i >= 5)

                if !isEnabled { continue }
                if isDiluent && !isCCR { continue }
                if o2s[i] == 0 && hes[i] == 0 { continue }

                h.gasMixes.append(
                    GasMix(
                        o2: Double(o2s[i]) / 100.0,
                        he: Double(hes[i]) / 100.0,
                        isDiluent: isDiluent
                    ))
            }
        }

        // Model & Timezone
        if let final = finalRecord, let modelByte = final.u8(at: 13) {
            h.isTeric = (modelByte == 8)
        }

        if h.isTeric && h.logVersion >= 9, let op5 = openingRecords[.opening5] {
            if let utcOffset = op5.u32be(at: 26).map({ Int32(bitPattern: $0) }),
                let dstByte = op5.u8(at: 30)
            {
                let dst = Int32(dstByte)
                h.timeZoneOffset = TimeInterval(utcOffset * 60 + dst * 3600)
            }
        }

        // Other Metadata
        if let op3 = openingRecords[.opening3] {
            if let density = op3.u16be(at: 3), density > 0 {
                h.waterDensity = Double(density)
            }

            // Calibration
            let mask = op3.u8(at: 6) ?? 0
            for i in 0..<3 {
                if (mask & (1 << i)) != 0, let calRaw = op3.u16be(at: 7 + i * 2) {
                    let factor = Double(calRaw) / 100000.0
                    // Predator (Model 2) fix would go here if we tracked model more precisely, omit for now or check finalRecord
                    h.calibration[i] = factor
                }
            }
        }

        if let op1 = openingRecords[.opening1] {
            if let p = op1.u16be(at: 16), p > 0 {
                h.surfacePressure = Double(p) / 1000.0
            }
        }

        // Tanks
        parseTanks(into: &h, openingRecords: openingRecords)

        return h
    }

    private static func parseTanks(into h: inout Headers, openingRecords: [RecordType: DataReader])
    {
        func formatSerial(_ b1: UInt8, _ b2: UInt8, _ b3: UInt8) -> String {
            if h.isTeric {
                return String(format: "%02X%02X%02X", b3, b2, b1)
            } else {
                return String(format: "%02X%02X%02X", b1, b2, b3)
            }
        }

        func addTank(name: String, b1: UInt8?, b2: UInt8?, b3: UInt8?) {
            guard let b1 = b1, let b2 = b2, let b3 = b3 else { return }
            let s = formatSerial(b1, b2, b3)
            if s != "000000" {
                h.tanks.append(DiveTank(name: name, sensorId: s))
            }
        }

        if let op5 = openingRecords[.opening5] {
            addTank(name: "Tank 1", b1: op5.u8(at: 1), b2: op5.u8(at: 2), b3: op5.u8(at: 3))
            addTank(name: "Tank 2", b1: op5.u8(at: 10), b2: op5.u8(at: 11), b3: op5.u8(at: 12))
        }
        if let op6 = openingRecords[.opening6] {
            addTank(name: "Tank 3", b1: op6.u8(at: 25), b2: op6.u8(at: 26), b3: op6.u8(at: 27))
        }
        if let op7 = openingRecords[.opening7] {
            addTank(name: "Tank 4", b1: op7.u8(at: 4), b2: op7.u8(at: 5), b3: op7.u8(at: 6))
        }
    }

    // --- Phase 3: Sample Parsing ---

    private struct SampleParseResult {
        var samples: [DiveSample]
        var pressureRecordsByTankIndex: [Int: [DiveTank.PressureRecord]]
    }

    private static func parseSamples(
        rawSamples: [(TimeInterval, DataReader)],
        rawSampleExts: [(TimeInterval, DataReader)],
        startTime: Date,
        headers: Headers
    ) -> SampleParseResult {
        var samples: [DiveSample] = []
        var pressureRecordsByTankIndex: [Int: [DiveTank.PressureRecord]] = [:]
        var lastO2: UInt8 = 0
        var lastHe: UInt8 = 0
        var lastIsOC: Bool? = nil

        func appendPressureRecord(
            _ pressureBar: Double?,
            tankIndex: Int,
            timestamp: Date
        ) {
            guard let pressureBar else { return }
            let record = DiveTank.PressureRecord(timestamp: timestamp, pressureBar: pressureBar)
            pressureRecordsByTankIndex[tankIndex, default: []].append(record)
        }

        func decodePressureBar(_ raw: UInt16?) -> Double? {
            guard let raw, raw < 0xFFF0 else { return nil }
            let masked = raw & 0x0FFF
            guard masked > 0 else { return nil }
            let pPsi = Double(masked) * 2.0
            return pPsi * 0.0689476
        }

        for (timeOffset, reader) in rawSamples {
            guard let statusByte = reader.u8(at: 12) else { continue }

            let isOC = (statusByte & 0x10) != 0
            let isExternalPPO2 = (statusByte & 0x02) == 0

            // Depth
            let depthRaw = reader.u16be(at: 1) ?? 0
            let depthMeters =
                headers.isImperial
                ? Double(depthRaw) * 0.3048 * 0.1
                : Double(depthRaw) * 0.1

            // Temp
            var tempCelsius: Double = 0
            if let tByte = reader.u8(at: 14) {
                var tempInt = Int(Int8(bitPattern: tByte))
                if tempInt < 0 {
                    tempInt += 102
                    if tempInt > 0 { tempInt = 0 }
                }
                tempCelsius =
                    headers.isImperial
                    ? (Double(tempInt) - 32.0) * (5.0 / 9.0)
                    : Double(tempInt)
            }

            // Pressure (Tank 1/2 from main sample record)
            if headers.logVersion >= 7 {
                let mainOffsets: [Int] = [28, 20]
                let baseIndex = (headers.aiMode == 4) ? 4 : 0
                for (idx, offset) in mainOffsets.enumerated() {
                    let pressureBar = decodePressureBar(reader.u16be(at: offset))
                    appendPressureRecord(
                        pressureBar,
                        tankIndex: baseIndex + idx,
                        timestamp: startTime.addingTimeInterval(timeOffset)
                    )
                }
            }

            // PPO2
            let ppo2 = reader.u8(at: 7).map { Double($0) / 100.0 }

            var ppo2Sensors: [Double]?
            if !isOC && isExternalPPO2 {
                let s0 = reader.u8(at: 13).map { Double($0) * headers.calibration[0] }
                let s1 = reader.u8(at: 15).map { Double($0) * headers.calibration[1] }
                let s2 = reader.u8(at: 16).map { Double($0) * headers.calibration[2] }
                if let s0, let s1, let s2 {
                    ppo2Sensors = [s0, s1, s2]
                }
            }

            let setpoint = reader.u8(at: 19).map { Double($0) / 100.0 }
            let cns = reader.u8(at: 23).map { Double($0) / 100.0 }

            // Deco
            var decoCeiling: Double?
            var decoStopDepth: Double?
            var decoStopTime: Double?
            var ndl: TimeInterval?

            let decoTimeMin = Double(reader.u8(at: 10) ?? 0)
            let stopDepthRaw = reader.u16be(at: 3) ?? 0

            if stopDepthRaw > 0 {
                let d =
                    headers.isImperial
                    ? Double(stopDepthRaw) * 0.3048
                    : Double(stopDepthRaw)
                decoStopDepth = d
                decoCeiling = d
                decoStopTime = decoTimeMin * 60
            } else {
                ndl = (decoTimeMin < 99) ? decoTimeMin * 60 : 99 * 60
            }

            let tts = reader.u16be(at: 5).map { Double($0) * 60.0 }

            // Events (Gas Change)
            var events: [DiveEvent] = []
            let gasO2 = reader.u8(at: 8) ?? 0
            let gasHe = reader.u8(at: 9) ?? 0
            let sampleGasMix: GasMix? = (gasO2 > 0 || gasHe > 0)
                ? GasMix(
                    o2: Double(gasO2) / 100.0,
                    he: Double(gasHe) / 100.0,
                    isDiluent: !isOC
                )
                : nil

            if gasO2 > 0 || gasHe > 0 {
                let gasChanged = (gasO2 != lastO2 || gasHe != lastHe)
                let modeChanged = (lastIsOC != nil && lastIsOC != isOC)

                if gasChanged || modeChanged {
                    let mix = GasMix(
                        o2: Double(gasO2) / 100.0,
                        he: Double(gasHe) / 100.0,
                        isDiluent: !isOC  // If we switched to it in CCR mode, likely a diluent switch
                    )

                    if isOC {
                        events.append(.gasChange(mix))
                    } else {
                        events.append(.diluentChange(mix))
                    }

                    lastO2 = gasO2
                    lastHe = gasHe
                }
            }
            lastIsOC = isOC

            let timestamp = startTime.addingTimeInterval(timeOffset)

            samples.append(
                DiveSample(
                    timestamp: timestamp,
                    depthMeters: depthMeters,
                    temperatureCelsius: tempCelsius,
                    ppo2: ppo2,
                    setpoint: setpoint,
                    cns: cns,
                    noDecompressionLimit: ndl,
                    decoCeiling: decoCeiling,
                    decoStopDepth: decoStopDepth,
                    decoStopTime: decoStopTime,
                    gasMix: sampleGasMix,
                    events: events,
                    diveMode: isOC ? .ocTec : .ccr,
                    ppo2Sensors: ppo2Sensors,
                    isExternalPPO2: isExternalPPO2,
                    tts: tts
                ))
        }

        if headers.logVersion >= 13 {
            for (timeOffset, reader) in rawSampleExts {
                let timestamp = startTime.addingTimeInterval(timeOffset)
                for i in 0..<2 {
                    let offset = 1 + i * 2
                    let pressureBar = decodePressureBar(reader.u16be(at: offset))
                    appendPressureRecord(pressureBar, tankIndex: 2 + i, timestamp: timestamp)
                }
                if headers.logVersion >= 14 {
                    for i in 0..<2 {
                        let offset = 5 + i * 2
                        let pressureBar = decodePressureBar(reader.u16be(at: offset))
                        appendPressureRecord(pressureBar, tankIndex: 4 + i, timestamp: timestamp)
                    }
                }
            }
        }

        return SampleParseResult(samples: samples, pressureRecordsByTankIndex: pressureRecordsByTankIndex)
    }
}
