import Foundation
import os

// MARK: - Simulated Transport

/// A simulated transport that mocks Bluetooth discovery and connection.
@MainActor
public final class SimulatedTransport: BluetoothTransport {
    private let simulatedDevices: [DiveComputerDescriptor]
    private var scanContinuation: AsyncThrowingStream<BluetoothDiscovery, Error>.Continuation?

    public var bluetoothState: AsyncStream<BluetoothState> {
        AsyncStream { continuation in
            continuation.yield(.poweredOn)
            // Never changes in simulation
        }
    }

    public init(simulatedDevices: [DiveComputerDescriptor] = [SimulatedDescriptor.makeDefault()]) {
        self.simulatedDevices = simulatedDevices
    }

    public func scan(descriptors: [DiveComputerDescriptor], timeout: Duration)
        -> AsyncThrowingStream<BluetoothDiscovery, Error>
    {
        return AsyncThrowingStream { continuation in
            self.scanContinuation = continuation

            Task {
                try? await Task.sleep(for: .seconds(0.5))  // Simulate scan delay

                for device in simulatedDevices {
                    let discovery = BluetoothDiscovery(
                        id: UUID(),  // Random UUID for every scan to simulate fresh discovery, or fixed?
                        descriptor: device,
                        name: "Simulated \(device.product)",
                        rssi: -50,
                        advertisedServices: device.serviceUUIDs
                    )
                    continuation.yield(discovery)
                }

                try? await Task.sleep(for: timeout)
                continuation.finish()
            }
        }
    }

    public func stopScan() {
        scanContinuation?.finish()
        scanContinuation = nil
    }

    public func connect(_ discovery: BluetoothDiscovery) async throws -> BluetoothLink {
        // Simulate connection delay
        try await Task.sleep(for: .seconds(1))
        return SimulatedLink(descriptor: discovery.descriptor)
    }
}

// MARK: - Simulated Link

@MainActor
public final class SimulatedLink: BluetoothLink {
    public let descriptor: DiveComputerDescriptor
    public let mtu: Int = 512
    public var isConnected: Bool = true

    init(descriptor: DiveComputerDescriptor) {
        self.descriptor = descriptor
    }

    public func read(from characteristic: BluetoothCharacteristic) async throws -> Data {
        throw BluetoothTransportError.unsupported
    }

    public func write(
        _ data: Data, to characteristic: BluetoothCharacteristic, type: BluetoothWriteType
    ) async throws {
        // No-op
    }

    public func enableNotifications(for characteristic: BluetoothCharacteristic) async throws {
        // No-op
    }

    public func getWriteType(for characteristic: BluetoothCharacteristic) async throws
        -> BluetoothWriteType
    {
        return .withResponse
    }

    public func notifications(for characteristic: BluetoothCharacteristic) -> AsyncThrowingStream<
        Data, Error
    > {
        AsyncThrowingStream { _ in }  // Empty stream
    }

    public func getDiscoveredCharacteristics(for service: BluetoothUUID) async throws
        -> [BluetoothCharacteristic]
    {
        return []
    }

    public func getWriteCharacteristic(for service: BluetoothUUID) async throws
        -> BluetoothCharacteristic?
    {
        return nil
    }

    public func getNotifyCharacteristic(for service: BluetoothUUID) async throws
        -> BluetoothCharacteristic?
    {
        return nil
    }

    public func close() async {
        // No-op
    }
}

// MARK: - Simulated Descriptor

public struct SimulatedDescriptor {
    public static let serviceUUID = BluetoothUUID("00000000-0000-0000-0000-000000000000")  // Dummy

    public static func makeDefault() -> DiveComputerDescriptor {
        // We reuse Shearwater vendor/product to test Shearwater-like behavior but with Simulated Driver
        return DiveComputerDescriptor(
            vendor: "Simulated",
            product: "Shearwater Simulator",
            capabilities: [.logDownload],
            services: [BluetoothServiceConfiguration(service: serviceUUID, characteristics: [:])],
            maximumMTU: 512
        )
    }
}

// MARK: - Simulated Driver

@MainActor
public final class SimulatedDriver: DiveComputerDriver {
    public let descriptor: DiveComputerDescriptor

    public init(descriptor: DiveComputerDescriptor = SimulatedDescriptor.makeDefault()) {
        self.descriptor = descriptor
    }

    public func open(link: BluetoothLink) async throws -> any DiveComputerDriverSession {
        return SimulatedDriverSession()
    }
}

// MARK: - Simulated Driver Session

@MainActor
public final class SimulatedDriverSession: DiveComputerDriverSession {
    private let bundledLogs: [DiveLog]

    public init() {
        // Load bundled logs once to ensure stable indices
        let (logs, _) = SimulatedDriverSession.loadBundledLogsWithSizes()
        // Sorted Newest to Oldest (by Start Time Descending)
        self.bundledLogs = logs.sorted { $0.startTime > $1.startTime }
    }

    public func readDeviceInfo() async throws -> DiveComputerInfo {
        return DiveComputerInfo(
            serialNumber: "SIM-123456",
            firmwareVersion: "v1.0.0-SIM",
            hardwareVersion: "SimulatedHW",
            batteryLevel: 0.85,
            lastSync: Date(),
            vendor: "Simulated",
            model: "Shearwater Simulator"
        )
    }

    public func downloadManifest() async throws -> [DiveLogCandidate] {
        // Simulate manifest download delay
        try await Task.sleep(for: .seconds(0.5))

        var candidates: [DiveLogCandidate] = []
        for (index, log) in bundledLogs.enumerated() {
            candidates.append(
                DiveLogCandidate(
                    id: index + 1,  // 1-based index usually
                    timestamp: log.startTime,
                    fingerprint: log.fingerprint ?? "UNKNOWN-\(index)",
                    metadata: ["index": String(index)]
                ))
        }
        return candidates
    }

    public func downloadDives(
        candidates: [DiveLogCandidate],
        progress: DiveDownloadProgress?
    ) async throws -> [DiveLog] {
        // Simulate 25KB/s download speed
        let chunkSize = 256
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
            let logSize = log.rawData?.count ?? 1024

            // Simulate slow download
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

    private static func loadBundledLogsWithSizes() -> ([DiveLog], [DiveLog: Int]) {
        var logs: [DiveLog] = []
        var sizes: [DiveLog: Int] = [:]
        let bundle = Bundle.module

        // Try subdirectory first
        var urls = bundle.urls(forResourcesWithExtension: "bin", subdirectory: "Resources")

        // Fallback to root if not found (SwiftPM .process behavior can vary)
        if urls == nil || urls?.isEmpty == true {
            urls = bundle.urls(forResourcesWithExtension: "bin", subdirectory: nil)
        }

        guard let foundUrls = urls, !foundUrls.isEmpty else {
            Logger.simulated.warning(
                "⚠️ SimulatedDevice: No .bin files found in Resources or bundle root. Bundle path: \(bundle.bundlePath)"
            )
            return ([], [:])
        }

        for url in foundUrls {
            do {
                let data = try Data(contentsOf: url)
                if let parsed = ShearwaterLogParser.parse(data: data) {
                    let log = DiveLog(
                        startTime: parsed.startTime,
                        duration: parsed.duration,
                        maxDepthMeters: parsed.maxDepth,
                        averageDepthMeters: parsed.avgDepth,
                        samples: parsed.samples,
                        gasMixes: parsed.gasMixes,
                        tanks: parsed.tanks,
                        decoModel: parsed.decoModel,
                        gradientFactorLow: parsed.gradientFactorLow,
                        gradientFactorHigh: parsed.gradientFactorHigh,
                        diveMode: parsed.diveMode,
                        waterDensity: parsed.waterDensity,
                        fingerprint: parsed.fingerprint?.map { String(format: "%02X", $0) }
                            .joined(),
                        rawData: data,
                        format: .shearwater
                    )
                    logs.append(log)
                    sizes[log] = data.count
                }
            } catch {
                Logger.simulated.error(
                    "⚠️ SimulatedDevice: Failed to load \(url.lastPathComponent): \(error)")
            }
        }
        return (logs, sizes)

    }

}
