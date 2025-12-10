import Foundation

public typealias DiveDownloadProgress = @Sendable (_ completed: Int, _ total: Int?) -> Void

@MainActor
public protocol DiveComputerDriverSession: Sendable {
    func readDeviceInfo() async throws -> DiveComputerInfo
    func downloadDiveLogs(progress: DiveDownloadProgress?) async throws -> [DiveLog]
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

    public func downloadDiveLogs(progress: DiveDownloadProgress? = nil) async throws -> [DiveLog] {
        try await driverSession.downloadDiveLogs(progress: progress)
    }

    public func liveSamples() -> AsyncThrowingStream<DiveSample, Error>? {
        driverSession.liveSamples()
    }

    public func close() async {
        await driverSession.close()
        await link.close()
    }
}
