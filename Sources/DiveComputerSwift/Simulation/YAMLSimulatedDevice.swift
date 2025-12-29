import Foundation
import os
import Yams

// MARK: - YAML Simulated Device

/// A simulated device that uses YAML files for easy editing and rich test data.
/// This provides an alternative to the binary-based SimulatedDevice for testing.

// MARK: - YAML Descriptor

public struct YAMLSimulatedDescriptor {
    public static let serviceUUID = BluetoothUUID("00000001-0000-0000-0000-000000000000")

    public static func makeDefault() -> DiveComputerDescriptor {
        return DiveComputerDescriptor(
            vendor: "Simulated",
            product: "YAML Test Device",
            capabilities: [.logDownload],
            services: [BluetoothServiceConfiguration(service: serviceUUID, characteristics: [:])],
            maximumMTU: 512
        )
    }
}

// MARK: - YAML Driver

@MainActor
public final class YAMLSimulatedDriver: DiveComputerDriver {
    public let descriptor: DiveComputerDescriptor

    public init(descriptor: DiveComputerDescriptor = YAMLSimulatedDescriptor.makeDefault()) {
        self.descriptor = descriptor
    }

    public func open(link: BluetoothLink) async throws -> any DiveComputerDriverSession {
        return YAMLSimulatedDriverSession()
    }
}

// MARK: - YAML Driver Session

@MainActor
public final class YAMLSimulatedDriverSession: DiveComputerDriverSession {
    private let bundledLogs: [DiveLog]

    public init() {
        let logs = YAMLDiveLogLoader.loadBundledLogs()
        print("DEBUG: YAMLSimulatedDriverSession init - loaded \(logs.count) dive logs from YAML")
        for (i, log) in logs.enumerated() {
            print(
                "DEBUG:   Log \(i): fingerprint=\(log.fingerprint ?? "nil"), startTime=\(log.startTimeLocal)"
            )
        }
        self.bundledLogs = logs.sorted { $0.startTimeUTC > $1.startTimeUTC }  // Newest first
    }

    public func readDeviceInfo() async throws -> DiveComputerInfo {
        return DiveComputerInfo(
            serialNumber: "YAML-TEST-001",
            firmwareVersion: "v2.0.0-YAML",
            hardwareVersion: "YAMLSimHW",
            batteryLevel: 0.95,
            lastSync: Date(),
            vendor: "Simulated",
            model: "YAML Test Device"
        )
    }

    public func downloadManifest() async throws -> [DiveLogCandidate] {
        try await Task.sleep(for: .milliseconds(300))

        var candidates: [DiveLogCandidate] = []
        for (index, log) in bundledLogs.enumerated() {
            candidates.append(
                DiveLogCandidate(
                    id: index + 1,
                    timestamp: log.startTimeUTC,
                    fingerprint: log.fingerprint ?? "YAML-UNKNOWN-\(index)",
                    metadata: ["index": String(index)]
                ))
        }
        print(
            "DEBUG: YAMLSimulatedDriverSession.downloadManifest returning \(candidates.count) candidates"
        )
        return candidates
    }

    public func downloadDives(
        candidates: [DiveLogCandidate],
        progress: DiveDownloadProgress?
    ) async throws -> [DiveLog] {
        // Fast simulated download (50KB/s)
        let chunkSize = 512
        let sleepPerChunk = Duration.milliseconds(10)

        var result: [DiveLog] = []
        let totalLogs = candidates.count

        for (i, candidate) in candidates.enumerated() {
            guard let indexStr = candidate.metadata["index"], let index = Int(indexStr),
                index < bundledLogs.count
            else {
                continue
            }

            let log = bundledLogs[index]
            let logSize = log.rawData?.count ?? 2048

            var downloaded = 0
            while downloaded < logSize {
                progress?(
                    DeviceTransferProgress(
                        currentLogIndex: i + 1,
                        totalLogs: totalLogs,
                        currentLogBytes: downloaded
                    ))
                try await Task.sleep(for: sleepPerChunk)
                downloaded += chunkSize
                if downloaded > logSize { downloaded = logSize }
            }

            progress?(
                DeviceTransferProgress(
                    currentLogIndex: i + 1,
                    totalLogs: totalLogs,
                    currentLogBytes: logSize
                ))

            result.append(log)
        }

        return result
    }

    public func liveSamples() -> AsyncThrowingStream<DiveSample, Error>? {
        return nil
    }

    public func close() async {
        // No-op
    }
}

// MARK: - YAML Dive Log Loader

public struct YAMLDiveLogLoader {

    public static func loadBundledLogs() -> [DiveLog] {
        let bundle = Bundle.module
        print("DEBUG: YAMLDiveLogLoader.loadBundledLogs - bundle path: \(bundle.bundlePath)")

        // Try subdirectory first
        var url = bundle.url(
            forResource: "sample_dives", withExtension: "yaml", subdirectory: "Resources")
        print(
            "DEBUG: Looking for sample_dives.yaml in Resources subdirectory: \(url?.absoluteString ?? "nil")"
        )

        // Fallback to root
        if url == nil {
            url = bundle.url(forResource: "sample_dives", withExtension: "yaml")
            print(
                "DEBUG: Looking for sample_dives.yaml in bundle root: \(url?.absoluteString ?? "nil")"
            )
        }

        guard let yamlUrl = url else {
            print("❌ YAMLSimulatedDevice: sample_dives.yaml not found in bundle")
            Logger.simulated.warning("⚠️ YAMLSimulatedDevice: sample_dives.yaml not found")
            return []
        }

        do {
            let yamlString = try String(contentsOf: yamlUrl, encoding: .utf8)
            print("DEBUG: Loaded YAML file, length: \(yamlString.count) characters")
            let logs = importYAML(yamlString)
            print("DEBUG: importYAML returned \(logs.count) dive logs")
            return logs
        } catch {
            print("❌ YAMLSimulatedDevice: Failed to load YAML: \(error)")
            Logger.simulated.error("⚠️ YAMLSimulatedDevice: Failed to load YAML: \(error)")
            return []
        }
    }

    // MARK: - YAML Parser

    public static func parse(_ yaml: String) -> DiveLog? {
        importYAML(yaml).first
    }

    static func importYAML(_ yaml: String) -> [DiveLog] {
        do {
            let yamlLogs = try decodeLogs(from: yaml)
            return yamlLogs.compactMap { createDiveLog(from: $0) }
        } catch {
            print("❌ YAMLSimulatedDevice: Failed to parse YAML: \(error)")
            Logger.simulated.error("⚠️ YAMLSimulatedDevice: Failed to parse YAML: \(error)")
            return []
        }
    }

    private struct YAMLDiveLogFile: Codable {
        var version: Int?
        var dives: [YAMLDiveLog]?
    }

    private struct YAMLDiveLog: Codable {
        var id: String?
        var fingerprint: String?
        var startTime: String?
        var startPositionLat: Double?
        var startPositionLong: Double?
        var endPositionLat: Double?
        var endPositionLong: Double?
        var durationSeconds: Double?
        var maxDepthMeters: Double?
        var averageDepthMeters: Double?
        var waterTemperatureCelsius: Double?
        var surfacePressureBar: Double?
        var diveMode: String?
        var waterDensity: Double?
        var decoModel: String?
        var gradientFactorLow: Double?
        var gradientFactorHigh: Double?
        var timeZoneOffsetSeconds: Double?
        var gasMixes: [YAMLGasMix]?
        var tanks: [YAMLTank]?
        var samples: [YAMLSample]?
    }

    private struct YAMLGasMix: Codable {
        var o2: Double?
        var he: Double?
        var isDiluent: Bool?

        init(o2: Double? = nil, he: Double? = nil, isDiluent: Bool? = nil) {
            self.o2 = o2
            self.he = he
            self.isDiluent = isDiluent
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            o2 = try container.decodeIfPresent(Double.self, forKey: .o2)
            he = try container.decodeIfPresent(Double.self, forKey: .he)
            if o2 == nil {
                o2 = try container.decodeIfPresent(Double.self, forKey: .oxygenFraction)
            }
            if he == nil {
                he = try container.decodeIfPresent(Double.self, forKey: .heliumFraction)
            }
            isDiluent = try container.decodeIfPresent(Bool.self, forKey: .isDiluent)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(o2, forKey: .o2)
            try container.encodeIfPresent(he, forKey: .he)
            try container.encodeIfPresent(isDiluent, forKey: .isDiluent)
        }

        private enum CodingKeys: String, CodingKey {
            case o2, he, isDiluent
            case oxygenFraction, heliumFraction
        }
    }

    private struct YAMLTank: Codable {
        var name: String?
        var volumeLiters: Double?
        var startPressureBar: Double?
        var endPressureBar: Double?
        var sensorId: String?
        var pressureRecords: [YAMLPressureRecord]?

        init(
            name: String? = nil,
            sensorId: String? = nil,
            volumeLiters: Double? = nil,
            startPressureBar: Double? = nil,
            endPressureBar: Double? = nil,
            pressureRecords: [YAMLPressureRecord]? = nil
        ) {
            self.name = name
            self.sensorId = sensorId
            self.volumeLiters = volumeLiters
            self.startPressureBar = startPressureBar
            self.endPressureBar = endPressureBar
            self.pressureRecords = pressureRecords
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            sensorId = try container.decodeIfPresent(String.self, forKey: .sensorId)
            if sensorId == nil {
                sensorId = try container.decodeIfPresent(String.self, forKey: .serialNumber)
            }
            volumeLiters = try container.decodeIfPresent(Double.self, forKey: .volumeLiters)
            startPressureBar = try container.decodeIfPresent(Double.self, forKey: .startPressureBar)
            endPressureBar = try container.decodeIfPresent(Double.self, forKey: .endPressureBar)
            pressureRecords = try container.decodeIfPresent(
                [YAMLPressureRecord].self,
                forKey: .pressureRecords
            )
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(name, forKey: .name)
            try container.encodeIfPresent(sensorId, forKey: .sensorId)
            try container.encodeIfPresent(volumeLiters, forKey: .volumeLiters)
            try container.encodeIfPresent(startPressureBar, forKey: .startPressureBar)
            try container.encodeIfPresent(endPressureBar, forKey: .endPressureBar)
            try container.encodeIfPresent(pressureRecords, forKey: .pressureRecords)
        }

        private enum CodingKeys: String, CodingKey {
            case name
            case sensorId
            case serialNumber
            case volumeLiters
            case startPressureBar
            case endPressureBar
            case pressureRecords
        }
    }

    private struct YAMLPressureRecord: Codable {
        var timestamp: String?
        var pressureBar: Double?
        var timeOffsetSeconds: Double?
    }

    private struct YAMLSample: Codable {
        var timeOffsetSeconds: Double?
        var depthMeters: Double?
        var temperatureCelsius: Double?
        var tankPressureBar: Double?
        var ppo2: Double?
        var setpoint: Double?
        var cns: Double?
        var ndlSeconds: Double?
        var decoCeilingMeters: Double?
        var decoStopDepthMeters: Double?
        var decoStopTimeSeconds: Double?
        var ttsSeconds: Double?
        var o2: Double?
        var he: Double?
        var events: [YAMLEvent]?
    }

    private struct YAMLEvent: Codable {
        var type: String?
        var o2: Double?
        var he: Double?
        var message: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decodeIfPresent(String.self, forKey: .type)
            o2 = try container.decodeIfPresent(Double.self, forKey: .o2)
            he = try container.decodeIfPresent(Double.self, forKey: .he)
            if o2 == nil {
                o2 = try container.decodeIfPresent(Double.self, forKey: .oxygenFraction)
            }
            if he == nil {
                he = try container.decodeIfPresent(Double.self, forKey: .heliumFraction)
            }
            message = try container.decodeIfPresent(String.self, forKey: .message)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(type, forKey: .type)
            try container.encodeIfPresent(o2, forKey: .o2)
            try container.encodeIfPresent(he, forKey: .he)
            try container.encodeIfPresent(message, forKey: .message)
        }

        private enum CodingKeys: String, CodingKey {
            case type, o2, he, message
            case oxygenFraction, heliumFraction
        }
    }

    private static func decodeLogs(from yaml: String) throws -> [YAMLDiveLog] {
        let decoder = YAMLDecoder()

        if let file = try? decoder.decode(YAMLDiveLogFile.self, from: yaml),
            let dives = file.dives
        {
            return dives
        }

        if let log = try? decoder.decode(YAMLDiveLog.self, from: yaml) {
            return [log]
        }

        if let logs = try? decoder.decode([YAMLDiveLog].self, from: yaml) {
            return logs
        }

        return []
    }

    private static func createDiveLog(from log: YAMLDiveLog) -> DiveLog? {
        let startTimeStr = log.startTime
        let startTimeUTC = startTimeStr.flatMap { parseISO8601($0) }
        let durationSecondsValue = log.durationSeconds
        let maxDepth = log.maxDepthMeters

        if startTimeStr == nil {
            print("DEBUG: createDiveLog FAILED - startTime is missing")
            return nil
        }
        if startTimeUTC == nil {
            print("DEBUG: createDiveLog FAILED - could not parse startTime: \(startTimeStr!)")
            return nil
        }
        let startTimeLocal = log.timeZoneOffsetSeconds.map {
            startTimeUTC!.addingTimeInterval(TimeInterval($0))
        } ?? startTimeUTC!
        if durationSecondsValue == nil {
            print("DEBUG: createDiveLog FAILED - durationSeconds is missing")
            return nil
        }
        if maxDepth == nil {
            print("DEBUG: createDiveLog FAILED - maxDepthMeters is missing")
            return nil
        }

        let durationSeconds = Int(durationSecondsValue!)
        let startPositionLat = log.startPositionLat
        let startPositionLong = log.startPositionLong
        let endPositionLat = log.endPositionLat
        let endPositionLong = log.endPositionLong

        let gasMixes: [GasMix] = (log.gasMixes ?? []).map { mix in
            GasMix(
                o2: mix.o2 ?? 0.21,
                he: mix.he ?? 0.0,
                isDiluent: mix.isDiluent ?? false
            )
        }

        var tanks: [DiveTank] = (log.tanks ?? []).map { tank in
            let records: [DiveTank.PressureRecord] =
                (tank.pressureRecords ?? []).compactMap { record in
                    guard let pressure = record.pressureBar else { return nil }
                    let timestamp: Date?
                    if let rawTimestamp = record.timestamp {
                        timestamp = parseISO8601(rawTimestamp)
                    } else if let offset = record.timeOffsetSeconds {
                        timestamp = startTimeUTC!.addingTimeInterval(offset)
                    } else {
                        timestamp = nil
                    }
                    guard let timestamp else { return nil }
                    return DiveTank.PressureRecord(timestamp: timestamp, pressureBar: pressure)
                }

            return DiveTank(
                name: tank.name,
                sensorId: tank.sensorId,
                volumeLiters: tank.volumeLiters,
                startPressureBar: tank.startPressureBar,
                endPressureBar: tank.endPressureBar,
                pressureRecords: records
            )
        }

        let parsedDiveMode = log.diveMode.flatMap { DiveMode(rawValue: $0) }
        let isCCRMode = parsedDiveMode == .ccr || parsedDiveMode == .semiClosed

        var samplePressureRecords: [DiveTank.PressureRecord] = []
        let samples: [DiveSample] = (log.samples ?? []).map { sample in
            let timeOffset = sample.timeOffsetSeconds.map { Int($0) } ?? 0
            let timestamp = startTimeUTC!.addingTimeInterval(TimeInterval(timeOffset))
            let sampleGasMix: GasMix? = (sample.o2 != nil || sample.he != nil)
                ? GasMix(
                    o2: sample.o2 ?? 0.21,
                    he: sample.he ?? 0.0,
                    isDiluent: isCCRMode
                )
                : nil

            let events: [DiveEvent] = (sample.events ?? []).compactMap { event in
                guard let type = event.type else { return nil }
                switch type {
                case "gasChange":
                    return .gasChange(
                        GasMix(
                            o2: event.o2 ?? 0.21,
                            he: event.he ?? 0.0,
                            isDiluent: false
                        )
                    )
                case "diluentChange":
                    return .diluentChange(
                        GasMix(
                            o2: event.o2 ?? 0.21,
                            he: event.he ?? 0.0,
                            isDiluent: true
                        )
                    )
                case "warning":
                    return event.message.map { .warning($0) }
                case "error":
                    return event.message.map { .error($0) }
                default:
                    return nil
                }
            }

            return DiveSample(
                timestamp: timestamp,
                depthMeters: sample.depthMeters ?? 0,
                temperatureCelsius: sample.temperatureCelsius,
                ppo2: sample.ppo2,
                setpoint: sample.setpoint,
                cns: sample.cns,
                noDecompressionLimit: sample.ndlSeconds.map { TimeInterval($0) },
                decoCeiling: sample.decoCeilingMeters,
                decoStopDepth: sample.decoStopDepthMeters,
                decoStopTime: sample.decoStopTimeSeconds.map { TimeInterval($0) },
                gasMix: sampleGasMix,
                events: events,
                diveMode: parsedDiveMode,
                tts: sample.ttsSeconds.map { TimeInterval($0) }
            )
        }

        for sample in log.samples ?? [] {
            guard let pressure = sample.tankPressureBar else { continue }
            let timeOffset = sample.timeOffsetSeconds.map { Int($0) } ?? 0
            let timestamp = startTimeUTC!.addingTimeInterval(TimeInterval(timeOffset))
            samplePressureRecords.append(
                DiveTank.PressureRecord(timestamp: timestamp, pressureBar: pressure)
            )
        }

        if !samplePressureRecords.isEmpty {
            if tanks.isEmpty {
                tanks = [
                    DiveTank(
                        name: "Tank 1",
                        startPressureBar: samplePressureRecords.first?.pressureBar,
                        endPressureBar: samplePressureRecords.last?.pressureBar,
                        pressureRecords: samplePressureRecords
                    )
                ]
            } else {
                tanks[0].pressureRecords.append(contentsOf: samplePressureRecords)
                if tanks[0].startPressureBar == nil {
                    tanks[0].startPressureBar = samplePressureRecords.first?.pressureBar
                }
                if tanks[0].endPressureBar == nil {
                    tanks[0].endPressureBar = samplePressureRecords.last?.pressureBar
                }
            }
        }

        let yamlData = createYAMLRepresentation(log)
        let diveMode = parsedDiveMode

        return DiveLog(
            startTimeUTC: startTimeUTC!,
            startTimeLocal: startTimeLocal,
            startPositionLat: startPositionLat,
            startPositionLong: startPositionLong,
            endPositionLat: endPositionLat,
            endPositionLong: endPositionLong,
            duration: .seconds(durationSeconds),
            maxDepthMeters: maxDepth!,
            averageDepthMeters: log.averageDepthMeters,
            waterTemperatureCelsius: log.waterTemperatureCelsius,
            surfacePressureBar: log.surfacePressureBar,
            samples: samples,
            gasMixes: gasMixes,
            tanks: tanks,
            decoModel: log.decoModel,
            gradientFactorLow: log.gradientFactorLow.map { Int($0) },
            gradientFactorHigh: log.gradientFactorHigh.map { Int($0) },
            diveMode: diveMode,
            waterDensity: log.waterDensity,
            fingerprint: log.fingerprint,
            rawData: yamlData,
            format: .yaml
        )
    }

    private static func parseISO8601(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            return date
        }

        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    private static func createYAMLRepresentation(_ log: YAMLDiveLog) -> Data {
        do {
            let encoder = YAMLEncoder()
            let yaml = try encoder.encode(log)
            return yaml.data(using: .utf8) ?? Data()
        } catch {
            print("DEBUG: Failed to encode YAML rawData: \(error)")
            return Data()
        }
    }
}
