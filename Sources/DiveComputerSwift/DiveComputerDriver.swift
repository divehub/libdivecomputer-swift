import Foundation

public struct DeviceTransferProgress: Sendable {
    public let currentLogIndex: Int
    public let totalLogs: Int
    
    // Optional because exact byte counts might not always be known upfront
    public let currentLogBytes: Int?
    
    public init(
        currentLogIndex: Int,
        totalLogs: Int,
        currentLogBytes: Int? = nil
    ) {
        self.currentLogIndex = currentLogIndex
        self.totalLogs = totalLogs
        self.currentLogBytes = currentLogBytes
    }
}

public typealias DiveDownloadProgress = @Sendable (DeviceTransferProgress) -> Void


public struct DiveLogCandidate: Sendable, Identifiable {
    public let id: Int // Index
    public let timestamp: Date?
    public let fingerprint: String
    public let metadata: [String: String]
    
    public init(id: Int, timestamp: Date?, fingerprint: String, metadata: [String: String] = [:]) {
        self.id = id
        self.timestamp = timestamp
        self.fingerprint = fingerprint
        self.metadata = metadata
    }
}

@MainActor
public protocol DiveComputerDriverSession: Sendable {
    func readDeviceInfo() async throws -> DiveComputerInfo
    /// Returns the manifest of available logs, ordered from NEWEST to OLDEST (matching device behavior).
    func downloadManifest() async throws -> [DiveLogCandidate]
    /// Downloads specific dives. Results must be returned in the same order as the provided candidates.
    func downloadDives(candidates: [DiveLogCandidate], progress: DiveDownloadProgress?) async throws -> [DiveLog]
    func liveSamples() -> AsyncThrowingStream<DiveSample, Error>?
    func close() async
}

@MainActor
public protocol DiveComputerDriver: Sendable {
    var descriptor: DiveComputerDescriptor { get }
    func open(link: BluetoothLink) async throws -> any DiveComputerDriverSession
}

@MainActor
public struct DiveComputerSession {
    public let descriptor: DiveComputerDescriptor
    private let link: BluetoothLink
    private let driverSession: any DiveComputerDriverSession

    init(
        descriptor: DiveComputerDescriptor,
        link: BluetoothLink,
        driverSession: any DiveComputerDriverSession
    ) {
        self.descriptor = descriptor
        self.link = link
        self.driverSession = driverSession
    }

    public func readDeviceInfo() async throws -> DiveComputerInfo {
        try await driverSession.readDeviceInfo()
    }

    public func downloadManifest() async throws -> [DiveLogCandidate] {
        try await driverSession.downloadManifest()
    }

    public func downloadDives(
        candidates: [DiveLogCandidate],
        progress: DiveDownloadProgress? = nil
    ) async throws -> [DiveLog] {
        try await driverSession.downloadDives(candidates: candidates, progress: progress)
    }

    public func liveSamples() -> AsyncThrowingStream<DiveSample, Error>? {
        driverSession.liveSamples()
    }

    public func close() async {
        await driverSession.close()
        await link.close()
    }
}
