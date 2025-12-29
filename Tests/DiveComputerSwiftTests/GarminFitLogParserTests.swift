import XCTest
@testable import DiveComputerSwift

final class GarminFitLogParserTests: XCTestCase {
    func testParseGarminFitSamples() throws {
        let fileNames = [
            "20790151505",
            "20798077560",
            "21019905244",
        ]

        let parser = GarminFitLogParser()
        for name in fileNames {
            let url = try XCTUnwrap(locateFitURL(named: name))
            let log = try parser.parse(
                fileURL: url,
                fingerprint: "garmin:\(name)"
            )

            printSummary(log: log, label: name)
            XCTAssertGreaterThan(log.samples.count, 0)

            if name == "20790151505" {
                let mixes = Set(log.samples.compactMap { $0.gasMix })
                XCTAssertGreaterThan(mixes.count, 1)

                let modes = Set(log.samples.compactMap { $0.diveMode })
                XCTAssertTrue(modes.contains(.ccr))
                XCTAssertTrue(modes.contains(.ocTec))
            }
        }
    }

    @MainActor
    func testGarminSimulatedDeviceFlow() async throws {
        let transport = SimulatedTransport(
            simulatedDevices: [GarminSimulatedDescriptor.makeDefault()]
        )
        let manager = DiveComputerManager(transport: transport)
        let driver = GarminSimulatedDriver()
        manager.register(driver: driver)

        var foundDiscovery: BluetoothDiscovery?
        let scanStream = manager.scan(timeout: .seconds(2))
        for try await discovery in scanStream {
            if discovery.descriptor.vendor == "Garmin" {
                foundDiscovery = discovery
                break
            }
        }

        XCTAssertNotNil(foundDiscovery, "Should find Garmin simulated device")
        guard let discovery = foundDiscovery else { return }

        manager.stopScan()
        let session = try await manager.connect(to: discovery)
        let info = try await session.readDeviceInfo()
        XCTAssertEqual(info.vendor, "Garmin")

        let manifest = try await session.downloadManifest()
        let logs = try await session.downloadDives(candidates: manifest, progress: nil)
        XCTAssertEqual(logs.count, manifest.count)
        XCTAssertGreaterThan(logs.count, 0)

        let sortedLogs = logs.sorted { $0.startTimeUTC > $1.startTimeUTC }
        XCTAssertEqual(
            logs.map { $0.startTimeUTC },
            sortedLogs.map { $0.startTimeUTC },
            "Logs should be returned sorted by date descending"
        )

        await session.close()
    }
}

private func printSummary(log: DiveLog, label: String) {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .medium
    formatter.timeZone = TimeZone(secondsFromGMT: 0)

    print("\n=== Garmin FIT Decode Summary: \(label) ===")
    print("Start: \(formatter.string(from: log.startTimeLocal))")
    print("Duration: \(log.duration)")
    print("Max Depth: \(String(format: "%.2f", log.maxDepthMeters)) m")
    if let avgDepth = log.averageDepthMeters {
        print("Avg Depth: \(String(format: "%.2f", avgDepth)) m")
    }
    if let temp = log.waterTemperatureCelsius {
        print("Avg Temp: \(String(format: "%.1f", temp)) C")
    }
    if let decoModel = log.decoModel {
        print("Deco Model: \(decoModel)")
    }
    if let gfLow = log.gradientFactorLow, let gfHigh = log.gradientFactorHigh {
        print("GF: \(gfLow)/\(gfHigh)")
    }
    if let diveMode = log.diveMode {
        print("Dive Mode: \(diveMode.rawValue)")
    }
    if let density = log.waterDensity {
        print("Water Density: \(String(format: "%.1f", density))")
    }

    print("Samples: \(log.samples.count)")
    print("Gas Mixes: \(log.gasMixes.count)")
    for (index, gas) in log.gasMixes.enumerated() {
        let o2 = Int((gas.o2 * 100).rounded())
        let he = Int((gas.he * 100).rounded())
        let tag = gas.isDiluent ? "(diluent)" : ""
        print("  Gas \(index + 1): O2 \(o2)% He \(he)% \(tag)")
    }

    let tanks = log.tanks
    print("Tanks: \(tanks.count)")
    for (index, tank) in tanks.enumerated() {
        let start = tank.startPressureBar.map { String(format: "%.1f", $0) } ?? "-"
        let end = tank.endPressureBar.map { String(format: "%.1f", $0) } ?? "-"
        print("  Tank \(index + 1): start \(start) bar, end \(end) bar")
    }

    let samplePreview = previewSamples(log.samples)
    if !samplePreview.isEmpty {
        print("Sample Preview:")
        for line in samplePreview {
            print("  \(line)")
        }
    }

    print("=== End Summary ===\n")
}

private func previewSamples(_ samples: [DiveSample]) -> [String] {
    guard !samples.isEmpty else { return [] }
    let formatter = DateFormatter()
    formatter.dateStyle = .none
    formatter.timeStyle = .medium

    let first = samples.prefix(3)
    let last = samples.suffix(3)
    var preview: [String] = []

    for sample in first {
        preview.append(formatSample(sample, formatter: formatter))
    }
    if samples.count > 6 {
        preview.append("... (\(samples.count - 6) samples omitted) ...")
    }
    for sample in last {
        preview.append(formatSample(sample, formatter: formatter))
    }

    return preview
}

private func formatSample(_ sample: DiveSample, formatter: DateFormatter) -> String {
    let time = formatter.string(from: sample.timestamp)
    let depth = String(format: "%.2f", sample.depthMeters)
    let temp = sample.temperatureCelsius.map { String(format: "%.1f", $0) } ?? "-"
    let ppo2 = sample.ppo2.map { String(format: "%.2f", $0) } ?? "-"
    let cns = sample.cns.map { String(format: "%.0f", $0) } ?? "-"
    let ndl = sample.noDecompressionLimit.map { String(format: "%.0f", $0) } ?? "-"
    return "\(time) | depth \(depth)m | temp \(temp)C | PPO2 \(ppo2) | CNS \(cns) | NDL \(ndl)s"
}

private func locateFitURL(named name: String) -> URL? {
    let bundle = Bundle.module
    if let url = bundle.url(forResource: name, withExtension: "fit", subdirectory: "Garmin") {
        return url
    }
    if let url = bundle.url(
        forResource: name,
        withExtension: "fit",
        subdirectory: "Resources/Garmin"
    ) {
        return url
    }
    return bundle.url(forResource: name, withExtension: "fit")
}
