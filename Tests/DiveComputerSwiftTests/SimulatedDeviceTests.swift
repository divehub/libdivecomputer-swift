import XCTest
@testable import DiveComputerSwift

final class SimulatedDeviceTests: XCTestCase {
    
    @MainActor
    func testSimulatedDeviceFlow() async throws {
        // 1. Setup Transport and Manager
        let transport = SimulatedTransport()
        let manager = DiveComputerManager(transport: transport)
        let driver = SimulatedDriver()
        manager.register(driver: driver)
        
        // 2. Scan
        var foundDiscovery: BluetoothDiscovery?
        let scanStream = manager.scan(timeout: .seconds(2))
        for try await discovery in scanStream {
            print("Found: \(discovery.name ?? "Unknown")")
            if discovery.descriptor.vendor == "Simulated" {
                foundDiscovery = discovery
                break // Stop after finding one
            }
        }
        
        XCTAssertNotNil(foundDiscovery, "Should find simulated device")
        guard let discovery = foundDiscovery else { return }
        
        // 3. Connect
        manager.stopScan()
        let session = try await manager.connect(to: discovery)
        
        // 4. Read Info
        let info = try await session.readDeviceInfo()
        XCTAssertEqual(info.serialNumber, "SIM-123456")
        
        // 5. Download Logs (All)
        let manifest = try await session.downloadManifest()
        let allLogs = try await session.downloadDives(candidates: manifest, progress: nil)
        XCTAssertGreaterThan(allLogs.count, 0, "Should have bundled logs")
        
        // 6. Test Fingerprint Filtering
        // Assume logs are [Latest, ..., Oldest] (Desc by Date)
        // Let's verify sort first
        let sortedLogs = allLogs.sorted { $0.startTime > $1.startTime }
        XCTAssertEqual(allLogs.map { $0.startTime }, sortedLogs.map { $0.startTime }, "Logs should be returned sorted by date descending")
        
        if allLogs.count >= 2 {
            let limitLog = allLogs[1] // The second log (older than first)
            guard let fp = limitLog.fingerprint else {
                XCTFail("Log should have fingerprint")
                return
            }
            
            // If we pass FP of 2nd log, we should get only the 1st log (Newer).
            // Logic: iterate Newest->Oldest. If FP matches, STOP. Return accumulated.
            // So if match is at index 1, result should be [index 0].
            
            var filtered: [DiveLogCandidate] = []
            for candidate in manifest {
                if candidate.fingerprint == fp {
                    break
                }
                filtered.append(candidate)
            }

            let newLogs = try await session.downloadDives(candidates: filtered, progress: nil)
            XCTAssertEqual(newLogs.count, 1, "Should return only 1 log (the newer one)")
            XCTAssertEqual(newLogs.first?.startTime, allLogs.first?.startTime, "The returned log should be the newest one")
        }
        
        await session.close()
    }
}
