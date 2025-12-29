import Foundation
import os

// MARK: - Garmin FIT Simulated Device

public struct GarminSimulatedDescriptor {
    public static let serviceUUID = BluetoothUUID("00000002-0000-0000-0000-000000000000")

    public static func makeDefault() -> DiveComputerDescriptor {
        DiveComputerDescriptor(
            vendor: "Garmin",
            product: "Garmin FIT Simulator",
            capabilities: [.logDownload],
            services: [BluetoothServiceConfiguration(service: serviceUUID, characteristics: [:])],
            maximumMTU: 512
        )
    }
}

@MainActor
public final class GarminSimulatedDriver: DiveComputerDriver {
    public let descriptor: DiveComputerDescriptor

    public init(descriptor: DiveComputerDescriptor = GarminSimulatedDescriptor.makeDefault()) {
        self.descriptor = descriptor
    }

    public func open(link: BluetoothLink) async throws -> any DiveComputerDriverSession {
        return GarminSimulatedDriverSession()
    }
}

@MainActor
public final class GarminSimulatedDriverSession: DiveComputerDriverSession {
    private let bundledLogs: [DiveLog]

    public init() {
        let logs = GarminFitLogLoader.loadBundledLogs()
        self.bundledLogs = logs.sorted { $0.startTimeUTC > $1.startTimeUTC }
    }

    public func readDeviceInfo() async throws -> DiveComputerInfo {
        DiveComputerInfo(
            serialNumber: "GARMIN-FIT-SIM",
            firmwareVersion: "v1.0.0-GARMIN",
            hardwareVersion: "GarminSimHW",
            batteryLevel: 0.9,
            lastSync: Date(),
            vendor: "Garmin",
            model: "Garmin FIT Simulator"
        )
    }

    public func downloadManifest() async throws -> [DiveLogCandidate] {
        try await Task.sleep(for: .milliseconds(10))

        var candidates: [DiveLogCandidate] = []
        for (index, log) in bundledLogs.enumerated() {
            candidates.append(
                DiveLogCandidate(
                    id: index + 1,
                    timestamp: log.startTimeUTC,
                    fingerprint: log.fingerprint ?? "garmin:unknown-\(index)",
                    metadata: ["index": String(index)]
                ))
        }
        return candidates
    }

    public func downloadDives(
        candidates: [DiveLogCandidate],
        progress: DiveDownloadProgress?
    ) async throws -> [DiveLog] {
        let chunkSize = 512
        let sleepPerChunk = Duration.milliseconds(1)

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
        nil
    }

    public func close() async {
        // No-op
    }
}

public struct GarminFitLogLoader {
    public static func loadBundledLogs() -> [DiveLog] {
        let bundle = Bundle.module
        var urls = bundle.urls(forResourcesWithExtension: "fit", subdirectory: "Garmin")

        if urls == nil || urls?.isEmpty == true {
            urls = bundle.urls(forResourcesWithExtension: "fit", subdirectory: nil)
        }

        guard let foundUrls = urls, !foundUrls.isEmpty else {
            Logger.simulated.warning(
                "GarminSimulatedDevice: No .fit files found in bundle at \(bundle.bundlePath)"
            )
            return []
        }

        let parser = GarminFitLogParser()
        var logs: [DiveLog] = []
        for url in foundUrls {
            do {
                let activityId = url.deletingPathExtension().lastPathComponent
                let fingerprint = "garmin:\(activityId)"
                let log = try parser.parse(fileURL: url, fingerprint: fingerprint)
                logs.append(log)
            } catch {
                Logger.simulated.error(
                    "GarminSimulatedDevice: Failed to parse \(url.lastPathComponent): \(error)"
                )
            }
        }

        return logs
    }
}
