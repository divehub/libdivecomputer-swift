import Foundation

/// A parser for Shearwater dive logs in the Petrel Native Format (PNF).
/// This format is used by Petrel, Petrel 2, Petrel 3, Perdix, Perdix 2, Teric, Peregrine, etc.
/// Legacy "Predator" format (128-byte blocks) is NOT supported.
public struct ShearwaterLogParser {

    public struct ParsedDive {
        public let startTime: Date
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
        public let waterDensity: Double?  // Added
        public let notes: String
        public let fingerprint: Data?
    }

    // Using global DiveSample and GasMix from DiveComputerModels.swift

    // Record types (First byte of the 32-byte block)
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

    // PNF Block Size is 32 bytes
    private static let blockSize = 32

    public static func parse(data: Data) -> ParsedDive? {
        // Enforce 32-byte alignment/size
        guard data.count >= blockSize else { return nil }

        var offset = 0
        var rawSamples: [(timeOffset: TimeInterval, data: Data)] = []
        var openingRecords: [UInt8: Data] = [:]
        var finalRecord: Data?

        // Default sample interval (can be overriden by Opening 5)
        var sampleInterval: TimeInterval = 10.0  // Default 10s
        var currentTime: TimeInterval = 0

        // --- First Pass: Collect raw blocks and metadata ---
        while offset + blockSize <= data.count {
            let blockData = data.subdata(in: offset..<offset + blockSize)
            let recordTypeByte = blockData[0]

            if let type = RecordType(rawValue: recordTypeByte) {
                switch type {
                case .diveSample:
                    // Advance time
                    currentTime += sampleInterval
                    rawSamples.append((currentTime, blockData))

                case .opening0, .opening1, .opening2, .opening3, .opening4, .opening5, .opening6,
                    .opening7:
                    openingRecords[recordTypeByte] = blockData

                    // If Opening 5, check sample interval
                    if type == .opening5 {
                        // Offset 23 in Opening 5 contains sample interval in ms
                        if 23 + 2 <= blockData.count {
                            let intervalMs = u16be(blockData, at: 23)
                            if intervalMs > 0 {
                                sampleInterval = TimeInterval(intervalMs) / 1000.0
                            }
                        }
                    }

                case .final:
                    finalRecord = blockData
                default:
                    break
                }
            }
            offset += blockSize
        }
        
        // --- Extract Fingerprint ---
        // Fingerprint is 4 bytes at offset 12 in Opening 0
        var fingerprint: Data?
        if let op0 = openingRecords[RecordType.opening0.rawValue], op0.count >= 16 {
            fingerprint = op0.subdata(in: 12..<16)
        }

        // --- Parse Start Time ---
        // From Opening Record 0 (0x10), offset 12 (Same as fingerprint)
        // Original format is usually a 32-bit timestamp
        var startTime: Date?
        if let op0 = openingRecords[RecordType.opening0.rawValue] {
            let timestamp = u32be(op0, at: 12)
            if timestamp > 0 {
                // If it looks like a valid epoch (e.g. > year 2000), use it
                // Shearwater timestamps are typically standard unix epoch
                startTime = Date(timeIntervalSince1970: TimeInterval(timestamp))
            }
        }
        
        // Fallback: Try Opening 2 (0x12) offset 20 if Opening 0 fails
        if startTime == nil, let op2 = openingRecords[RecordType.opening2.rawValue] {
             let timestamp = u32be(op2, at: 20)
             if timestamp > 0 {
                 startTime = Date(timeIntervalSince1970: TimeInterval(timestamp))
             }
        }
        
        // --- Process Metadata FIRST (Dependencies for Samples) ---

        // 2. Units (Opening 0, Byte 8)
        var isImperial = false
        if let op0 = openingRecords[RecordType.opening0.rawValue], op0.count > 8 {
            isImperial = (op0[8] == 1)
        }

        // 3. Log Version (Opening 4, Byte 16) & Dive Mode
        var logVersion: Int = 0
        var diveMode: DiveMode?

        if let op4 = openingRecords[RecordType.opening4.rawValue] {
            if 16 < op4.count { logVersion = Int(op4[16]) }

            if 1 < op4.count {
                let modeByte = op4[1]
                switch modeByte {
                case 0, 5: diveMode = .ccr
                case 1: diveMode = .ocTec
                case 2: diveMode = .gauge
                case 3: diveMode = .ppo2
                case 4: diveMode = .semiClosed
                case 6: diveMode = .ocRec
                case 7: diveMode = .freedive
                case 12: diveMode = .avelo
                default: diveMode = .unknown
                }
            }
        }

        // 4. Deco Model (Opening 2)
        var decoModel: String?
        if let op2 = openingRecords[RecordType.opening2.rawValue] {
            if 18 < op2.count {
                let modelByte = op2[18]
                switch modelByte {
                case 0: decoModel = "Buhlmann ZHL-16C"
                case 1: decoModel = "VPM-B"
                case 2: decoModel = "VPM-B/GFS"
                case 3: decoModel = "DCIEM"
                default: decoModel = "Unknown (\(modelByte))"
                }
            }
        }

        // 5. Water Density
        // Opening 3: Density
        var waterDensity: Double?
        if let op3 = openingRecords[RecordType.opening3.rawValue] {
            let densityRaw = u16be(op3, at: 3)
            if densityRaw > 0 {
                waterDensity = Double(densityRaw)
            }
        }

        // 6. Tanks (Opening 5, 6, 7)
        var tanks: [DiveTank] = []
        var model = 0
        if let final = finalRecord, 13 < final.count {
            model = Int(final[13])
        }
        let isTeric = (model == 8)

        func formatSerial(_ b1: UInt8, _ b2: UInt8, _ b3: UInt8) -> String {
            if isTeric {
                return String(format: "%02X%02X%02X", b3, b2, b1)
            } else {
                return String(format: "%02X%02X%02X", b1, b2, b3)
            }
        }

        if let op5 = openingRecords[RecordType.opening5.rawValue] {
            // Tank 1 (Offset 1)
            if op5.count > 3 {
                let s1 = formatSerial(op5[1], op5[2], op5[3])
                if s1 != "000000" {
                    tanks.append(DiveTank(name: "Tank 1", serialNumber: s1, usage: .unknown))
                }
            }
            // Tank 2 (Offset 10)
            if op5.count > 12 {
                let s2 = formatSerial(op5[10], op5[11], op5[12])
                if s2 != "000000" {
                    tanks.append(DiveTank(name: "Tank 2", serialNumber: s2, usage: .unknown))
                }
            }
        }

        if let op6 = openingRecords[RecordType.opening6.rawValue] {
            // Tank 3 (Offset 25)
            if op6.count > 27 {
                let s3 = formatSerial(op6[25], op6[26], op6[27])
                if s3 != "000000" {
                    tanks.append(DiveTank(name: "Tank 3", serialNumber: s3, usage: .unknown))
                }
            }
        }

        if let op7 = openingRecords[RecordType.opening7.rawValue] {
            // Tank 4 (Offset 4)
            if op7.count > 6 {
                let s4 = formatSerial(op7[4], op7[5], op7[6])
                if s4 != "000000" {
                    tanks.append(DiveTank(name: "Tank 4", serialNumber: s4, usage: .unknown))
                }
            }
        }

        // 8. Gases & GF (Opening 0)
        var gasMixes: [GasMix] = []
        var gfLow: Int?
        var gfHigh: Int?

        if let op0 = openingRecords[RecordType.opening0.rawValue] {
            if 5 < op0.count {
                gfLow = Int(op0[4])
                gfHigh = Int(op0[5])
            }

            var o2s: [UInt8] = []
            for i in 0..<5 {
                if 20 + i < op0.count { o2s.append(op0[20 + i]) } else { o2s.append(0) }
            }

            var hes: [UInt8] = [0, 0, 0, 0, 0]
            if 30 < op0.count { hes[0] = op0[30] }
            if 31 < op0.count { hes[1] = op0[31] }

            // Opening 1 has more He
            if let op1 = openingRecords[RecordType.opening1.rawValue] {
                if 1 < op1.count { hes[2] = op1[1] }
                if 2 < op1.count { hes[3] = op1[2] }
                if 3 < op1.count { hes[4] = op1[3] }
            }

            for i in 0..<5 {
                if o2s[i] > 0 {
                    gasMixes.append(
                        GasMix(
                            oxygenFraction: Double(o2s[i]) / 100.0,
                            heliumFraction: Double(hes[i]) / 100.0
                        ))
                }
            }
        }

        // 9. Surface Pressure (Opening 1)
        var surfacePressureBar: Double?
        if let op1 = openingRecords[RecordType.opening1.rawValue] {
            let pressureMbar = u16be(op1, at: 16)
            if pressureMbar > 0 {
                surfacePressureBar = Double(pressureMbar) / 1000.0
            }
        }

        // 10. Calibration (Opening 3)
        var calibration: [Double] = [0.0, 0.0, 0.0]

        if let op3 = openingRecords[RecordType.opening3.rawValue], op3.count > 12 {
            // Index 6 is mask
            let mask = op3[6]
            for i in 0..<3 {
                if (mask & (1 << i)) != 0 {
                    let calRaw = u16be(op3, at: 7 + i * 2)
                    var factor = Double(calRaw) / 100000.0
                    // Predator (Model 2) Fix
                    if model == 2 {
                        factor *= 2.2
                    }
                    calibration[i] = factor
                }
            }
        }

        // --- 2nd Pass: Process Samples ---
        var samples: [DiveSample] = []
        var lastO2: UInt8 = 0
        var lastHe: UInt8 = 0
        var lastIsOC: Bool? = nil

        for (timeOffset, blockData) in rawSamples {
            // Byte 1: Depth MSB
            // Status Flags are at Offset 12 (Index 12) for PNF
            let statusByte = blockData[12]
            // OC bit is 0x10 (Bit 4). If set, it's OC. If clear, it's CCR.
            let isOC = (statusByte & 0x10) != 0

            // PPO2 External (0x02). User/Analysis suggests 0 means External (or Active Sensors).
            let isExternalPPO2 = (statusByte & 0x02) == 0

            // Mask Depth (14 bits) -> C code does NOT mask.
            // C: unsigned int depth = array_uint16_be (data + pnf + offset);
            let depthRaw = u16be(blockData, at: 1)
            let depthMeters: Double
            if isImperial {
                // C: sample.depth = depth * FEET / 10.0;
                // FEET = 0.3048
                depthMeters = Double(depthRaw) * 0.3048 * 0.1
            } else {
                depthMeters = Double(depthRaw) * 0.1
            }

            // Temp
            // Temp
            var tempCelsius: Double
            // C code: data[offset + pnf + 13] -> Index 14 for PNF
            if 14 < blockData.count {
                var tempInt = Int(Int8(bitPattern: blockData[14]))

                // C-style fix for negative temperatures
                if tempInt < 0 {
                    tempInt += 102
                    if tempInt > 0 { tempInt = 0 }
                }

                if isImperial {
                    // C code: (temp - 32) * 5/9.
                    // Shearwater stores F if unit bit is set.
                    tempCelsius = (Double(tempInt) - 32.0) * (5.0 / 9.0)
                } else {
                    tempCelsius = Double(tempInt)
                }
            } else {
                tempCelsius = 0
            }

            // Tank Pressure (AI)
            var pressureBar: Double? = nil
            // Check AI Mode from Opening 4
            // LogVersion >= 7 checks Byte 28.
            var isAIEnabled = false
            if let op4 = openingRecords[RecordType.opening4.rawValue], op4.count > 28 {
                let aiMode = op4[28]
                isAIEnabled = (aiMode != 0)
            }

            if isAIEnabled {
                // User snippet suggests Offset 27.
                // C code suggests offset + pnf + 27 (28 if PNF).
                // We'll trust User Snippet for LogVer 14.
                let pressureOffset = (logVersion > 14) ? 28 : 27

                if pressureOffset + 1 < blockData.count {
                    let pressureRaw = u16be(blockData, at: pressureOffset)
                    if pressureRaw < 0xFFF0 {
                        let pressurePsi = Double(pressureRaw & 0x0FFF) * 2.0
                        pressureBar = pressurePsi * 0.0689476
                    }
                }
            }

            // Detailed Fields
            var ppo2: Double?
            var setpoint: Double?
            var cns: Double?
            var ppo2Sensors: [Double]?

            // Logic PPO2 is at Index 7
            let ppo2Value = Double(blockData[7]) / 100.0
            if ppo2Value > 0 { ppo2 = ppo2Value }

            // Sensors (Internal/External) if NOT OC and Flag implies Sensors Present
            // If isExternalPPO2 (from 0x02 == 0) is true, we parse.
            if !isOC && isExternalPPO2 {
                // Sensor 0: Index 13 (offset 12 + 1)
                // Sensor 1: Index 15 (offset 14 + 1)
                // Sensor 2: Index 16 (offset 15 + 1)
                if blockData.count > 16 {
                    let s0 = Double(blockData[13]) * calibration[0]
                    let s1 = Double(blockData[15]) * calibration[1]
                    let s2 = Double(blockData[16]) * calibration[2]
                    ppo2Sensors = [s0, s1, s2]
                }
            }

            let sp = Double(blockData[19]) / 100.0
            if sp > 0 { setpoint = sp }

            let cnsVal = Double(blockData[23]) / 100.0
            cns = cnsVal

            // Deco
            let stopDepthRaw = u16be(blockData, at: 3)
            var decoCeiling: Double?
            var decoStopDepth: Double?
            var decoStopTime: Double?
            var noDecompressionLimit: TimeInterval?

            let decoTimeMin = Double(blockData[10])

            var tts: TimeInterval?
            // C: sample.deco.tts = array_uint16_be (data + offset + pnf + 4) * 60;
            // PNF=1, so index is 1+4 = 5.
            let ttsMin = u16be(blockData, at: 5)
            if ttsMin > 0 {
                tts = Double(ttsMin) * 60.0
            }

            if stopDepthRaw > 0 {
                let depth = Double(stopDepthRaw)  // m
                decoStopDepth = depth
                decoCeiling = depth
                decoStopTime = decoTimeMin * 60
            } else {
                if decoTimeMin < 99 {
                    noDecompressionLimit = decoTimeMin * 60
                } else {
                    noDecompressionLimit = 99 * 60
                }
            }

            var events: [DiveEvent] = []

            // Gas Change
            let gasO2 = blockData[8]
            let gasHe = blockData[9]

            if gasO2 > 0 || gasHe > 0 {
                let gasChanged = (gasO2 != lastO2 || gasHe != lastHe)
                let modeChanged = (lastIsOC != nil && lastIsOC != isOC)

                if gasChanged || modeChanged {
                    // Emit event
                    let mix = GasMix(
                        oxygenFraction: Double(gasO2) / 100.0, heliumFraction: Double(gasHe) / 100.0
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

            let sample = DiveSample(
                timestamp: (startTime ?? Date()).addingTimeInterval(timeOffset),
                depthMeters: depthMeters,
                temperatureCelsius: tempCelsius,
                tankPressureBar: pressureBar,
                ppo2: ppo2,
                setpoint: setpoint,
                cns: cns,
                noDecompressionLimit: noDecompressionLimit,
                decoCeiling: decoCeiling,
                decoStopDepth: decoStopDepth,
                decoStopTime: decoStopTime,
                events: events,
                diveMode: isOC ? .ocTec : .ccr,
                ppo2Sensors: ppo2Sensors,
                isExternalPPO2: isExternalPPO2,
                tts: tts
            )
            samples.append(sample)
        }

        guard let finalStartTime = startTime, !samples.isEmpty else {
            return nil
        }

        let maxDepth = samples.max(by: { $0.depthMeters < $1.depthMeters })?.depthMeters ?? 0
        let avgDepth = samples.reduce(0.0) { $0 + $1.depthMeters } / Double(samples.count)

        return ParsedDive(
            startTime: finalStartTime,
            duration: .seconds(currentTime),
            maxDepth: maxDepth,
            avgDepth: avgDepth,
            surfacePressure: surfacePressureBar,
            samples: samples,
            gasMixes: gasMixes,
            tanks: tanks,
            decoModel: decoModel,
            gradientFactorLow: gfLow,
            gradientFactorHigh: gfHigh,
            diveMode: diveMode,
            waterDensity: waterDensity,
            notes: "Imported from Shearwater Log (PNF)",
            fingerprint: fingerprint
        )
    }

    // Helpers
    private static func u16be(_ data: Data, at offset: Int) -> UInt16 {
        guard offset + 1 < data.count else { return 0 }
        return (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func u32be(_ data: Data, at offset: Int) -> UInt32 {
        guard offset + 3 < data.count else { return 0 }
        return (UInt32(data[offset]) << 24) | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8) | UInt32(data[offset + 3])
    }
}
