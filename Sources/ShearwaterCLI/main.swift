import DiveComputerSwift
import Foundation

#if canImport(CoreBluetooth)
    import CoreBluetooth
#endif

#if canImport(CoreBluetooth)
    @MainActor
    class ShearwaterCLI: NSObject {
        private var transport: CoreBluetoothTransport?
        private var manager: DiveComputerManager?
        private var isScanning = false
        private var discoveredDevices: [BluetoothDiscovery] = []

        func run(fingerprint: Data? = nil) async throws {
            print("🔷 Shearwater CLI Testing Tool")
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            if let fp = fingerprint {
                print(
                    "🔒 Syncing from fingerprint: \(fp.map { String(format: "%02X", $0) }.joined())")
            }
            print()

            // Initialize transport
            transport = CoreBluetoothTransport()
            manager = DiveComputerManager(transport: transport!)

            print("📡 Initializing Bluetooth...")
            // No explicit waitForReady needed - scan will wait automatically
            print("✅ Bluetooth initialized")
            print()

            // Scan for devices
            print("🔍 Scanning for Shearwater devices...")
            let descriptor = ShearwaterDescriptor.makeDefault()

            let scanStream = transport!.scan(descriptors: [descriptor], timeout: .seconds(30))
            var scanTask: Task<Void, Never>?

            scanTask = Task {
                do {
                    for try await discovery in scanStream {
                        if !discoveredDevices.contains(where: { $0.id == discovery.id }) {
                            discoveredDevices.append(discovery)
                            print("📱 Found: \(discovery.name ?? "Unknown") (\(discovery.id))")
                            print("   RSSI: \(discovery.rssi) dBm")
                            print("   Vendor: \(discovery.descriptor.vendor)")
                            print("   Product: \(discovery.descriptor.product)")
                            print()

                            // Stop scanning after finding first device
                            print("✅ Device found, stopping scan...")
                            break
                        }
                    }
                } catch {
                    print("❌ Scan error: \(error)")
                }
            }

            // Wait for scan task to complete (either found device or timeout)
            await scanTask?.value

            transport!.stopScan()

            guard let device = discoveredDevices.first else {
                print("❌ No Shearwater devices found")
                print()
                print("Make sure:")
                print("  • Your Shearwater is powered on")
                print("  • Bluetooth is enabled on your Shearwater")
                print("  • The device is in range")
                return
            }

            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            print("🔗 Connecting to \(device.name ?? "Unknown")...")
            print()

            // Connect
            let link = try await transport!.connect(device)
            print("✅ Connected")
            print()

            // Open driver
            print("🔧 Opening Shearwater driver...")
            let driver = ShearwaterDriver()
            // Force cast to ShearwaterSession to access extra methods
            let session = try await driver.open(link: link) as! ShearwaterSession
            print("✅ Driver opened")
            print()

            // Read device info
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            print("📋 Reading device information...")
            print()

            do {
                let info = try await session.readDeviceInfo()
                print("✅ Device Info:")
                print("   Model: \(info.model ?? "Unknown")")
                print("   Serial: \(info.serialNumber ?? "Unknown")")
                print("   Firmware: \(info.firmwareVersion ?? "Unknown")")
                print("   Hardware: \(info.hardwareVersion ?? "Unknown")")
                print()
            } catch {
                print("❌ Failed to read device info: \(error)")
                print()
            }

            // Download dive logs
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            print("📥 Downloading dive logs...")
            print()

            do {
                let progressHandler: DiveDownloadProgress = { completed, total in
                    if let total = total {
                        let percent = Int((Double(completed) / Double(total)) * 100)
                        print(
                            "\r   Progress: \(completed)/\(total) bytes (\(percent)%)  ",
                            terminator: "")
                        fflush(stdout)
                    }
                }

                let onRawData: (Int, Data) -> Void = { index, data in
                    let filename = "dive_log_\(String(format: "%02d", index)).bin"
                    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                        .appendingPathComponent(filename)
                    do {
                        try data.write(to: url)
                        print("\n   💾 Saved raw dive log to \(filename) (\(data.count) bytes)")
                    } catch {
                        print("\n   ❌ Failed to save raw dive log: \(error)")
                    }
                }

                let dives = try await session.downloadDiveLogs(
                    fingerprint: fingerprint, progress: progressHandler, onRawData: onRawData)

                print()  // New line after progress
                print("✅ Downloaded \(dives.count) dive(s)")
                print()

                for (index, dive) in dives.prefix(5).enumerated() {
                    print("  Dive #\(index + 1):")
                    print("    Date: \(dive.startTime)")
                    print("    Duration: \(dive.duration)")
                    print("    Max Depth: \(dive.maxDepthMeters)m")
                    if let avgDepth = dive.averageDepthMeters {
                        print("    Avg Depth: \(avgDepth)m")
                    }
                    print("    Samples: \(dive.samples.count)")
                    if !dive.gasMixes.isEmpty {
                        print("    Gases: \(dive.gasMixes.count)")
                    }
                    print()
                }

                if dives.count > 5 {
                    print("  ... and \(dives.count - 5) more dive(s)")
                    print()
                }
            } catch {
                print()
                print("❌ Failed to download dives: \(error)")
                print()
            }

            // Close
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            print("🔌 Closing connection...")
            await session.close()
            await link.close()
            print("✅ Disconnected")
            print()
            print("✨ Test complete!")
        }
    }
#endif

    @MainActor
    func main() async {
        // Parse arguments
        var fingerprint: Data? = nil
        var filePath: String? = nil

        var i = 1
        while i < CommandLine.arguments.count {
            let arg = CommandLine.arguments[i]
            if arg == "--fingerprint" {
                if i + 1 < CommandLine.arguments.count {
                    let hex = CommandLine.arguments[i + 1]
                    // Convert hex string to Data
                    var data = Data()
                    var startIndex = hex.startIndex
                    while startIndex < hex.endIndex {
                        let endIndex = hex.index(startIndex, offsetBy: 2)
                        if let byte = UInt8(hex[startIndex..<endIndex], radix: 16) {
                            data.append(byte)
                        }
                        startIndex = endIndex
                    }
                    fingerprint = data
                    i += 2
                    print(
                        "🔑 Parsed fingerprint: \(data.map { String(format: "%02X", $0) }.joined())")
                    continue
                }
            } else if !arg.hasPrefix("-") {
                // Assume it's a file path if not a flag
                filePath = arg
            }
            i += 1
        }

        // specific check for command line arguments to parse a file
        if let path = filePath {
            print("🔷 Parse File Mode")
            print("   File: \(path)")
            print()

            let url = URL(fileURLWithPath: path)
            do {
                let data = try Data(contentsOf: url)
                print("   Read \(data.count) bytes")

                if let parsed = ShearwaterLogParser.parse(data: data) {
                    print("✅ Parse Successful:")
                    if let fp = parsed.fingerprint {
                        print(
                            "   Fingerprint: \(fp.map { String(format: "%02X", $0) }.joined())"
                        )
                    }
                    print("   Start Time: \(parsed.startTime)")
                    print("   Duration:   \(parsed.duration)")
                    print("   Max Depth:  \(parsed.maxDepth)m")
                    print("   Avg Depth:  \(parsed.avgDepth)m")
                    if let surface = parsed.surfacePressure {
                        print("   Surface:    \(String(format: "%.3f", surface)) bar")
                    }
                    print("   Samples:    \(parsed.samples.count)")
                    // print("   Events:     \(parsed.events.count)") // Not parsed yet
                    print("   Gases:      \(parsed.gasMixes.count)")
                    for (i, gas) in parsed.gasMixes.enumerated() {
                        print(
                            "     [\(i)] O2: \(Int(gas.oxygenFraction * 100))% He: \(Int(gas.heliumFraction * 100))%"
                        )
                    }
                    print("   Tanks:      \(parsed.tanks.count)")
                    for (i, tank) in parsed.tanks.enumerated() {
                        print(
                            "     [\(i)] \(tank.name ?? "Unknown") (SN: \(tank.serialNumber ?? "N/A"))"
                        )
                    }
                    if let diveMode = parsed.diveMode {
                        print("   Mode:       \(diveMode.rawValue)")
                    }
                    if let model = parsed.decoModel {
                        print("   Deco Model: \(model)")
                    }
                    if let low = parsed.gradientFactorLow, let high = parsed.gradientFactorHigh {
                        print("   GF:         \(low)/\(high)")
                    }
                    if let density = parsed.waterDensity {
                        print("   Density:    \(String(format: "%.1f g/L", density))")
                    }

                    // Events
                    let allEvents = parsed.samples.compactMap {
                        sample -> (TimeInterval, [DiveEvent])? in
                        if sample.events.isEmpty { return nil }
                        return (sample.timestamp.timeIntervalSince(parsed.startTime), sample.events)
                    }

                    if !allEvents.isEmpty {
                        print()
                        print("   Events:")
                        for (time, events) in allEvents {
                            let timeStr = String(format: "T+%0.0fs", time)
                            for event in events {
                                switch event {
                                case .gasChange(let mix):
                                    print(
                                        "     \(timeStr): Gas Change -> O2:\(Int(mix.oxygenFraction * 100))% He:\(Int(mix.heliumFraction * 100))%"
                                    )
                                case .diluentChange(let mix):
                                    print(
                                        "     \(timeStr): Diluent Switch -> O2:\(Int(mix.oxygenFraction * 100))% He:\(Int(mix.heliumFraction * 100))%"
                                    )
                                case .warning(let msg):
                                    print("     \(timeStr): Warning: \(msg)")
                                case .error(let msg):
                                    print("     \(timeStr): Error: \(msg)")
                                case .unknown(let code):
                                    print("     \(timeStr): Event Code \(code)")
                                }
                            }
                        }
                    }

                    if !parsed.samples.isEmpty {
                        print()
                        print("   Sample Data (First 20):")
                        for (i, sample) in parsed.samples.prefix(20).enumerated() {
                            let relativeTime = sample.timestamp.timeIntervalSince(parsed.startTime)
                            let timeString = String(format: "T+%0.0fs", relativeTime)
                            let depthString = String(format: "%0.1fm", sample.depthMeters)
                            let tempString =
                                sample.temperatureCelsius.map { String(format: "%0.1f°C", $0) }
                                ?? "-"
                            let pressureString =
                                sample.tankPressureBar.map { String(format: "P:%0.1fbar", $0) }
                                ?? ""
                            let modeString = sample.diveMode.map { "Mode:\($0.rawValue)" } ?? ""

                            var details: [String] = []
                            if let ppo2 = sample.ppo2 {
                                var ppo2Str = String(format: "PPO2:%0.2f", ppo2)
                                if sample.isExternalPPO2 == true { ppo2Str += "(Ext)" }
                                details.append(ppo2Str)
                            }
                            if let sensors = sample.ppo2Sensors, !sensors.isEmpty {
                                let vals = sensors.map { String(format: "%0.2f", $0) }.joined(
                                    separator: "|")
                                details.append("Sens:[\(vals)]")
                            }
                            if let sp = sample.setpoint {
                                details.append(String(format: "SP:%0.2f", sp))
                            }
                            if let cns = sample.cns {
                                details.append(String(format: "CNS:%0.2f", cns))
                            }

                            if let sd = sample.decoStopDepth, let st = sample.decoStopTime {
                                details.append(String(format: "Deco:%0.0fm/%0.0f'", sd, st / 60.0))
                            } else if let ndl = sample.noDecompressionLimit {
                                details.append(String(format: "NDL:%0.0f'", ndl / 60.0))
                            }

                            if let tts = sample.tts {
                                details.append(String(format: "TTS:%0.0f'", tts / 60.0))
                            }

                            let detailsStr = details.joined(separator: " ")

                            print(
                                "     [\(i)] \(timeString): \(depthString) \(tempString) \(pressureString) \(modeString) \(detailsStr)"
                            )
                        }
                    }  // End if !samples.isEmpty
                } else {
                    print("❌ Failed to parse data")
                }
            } catch {
                print("❌ Error reading file: \(error)")
            }
            return
        }

        #if canImport(CoreBluetooth)
        let cli = ShearwaterCLI()
        do {
            try await cli.run(fingerprint: fingerprint)
        } catch {
            print()
            print("❌ Fatal error: \(error)")
            print()
            exit(1)
        }
        #else
        print("❌ Bluetooth features require CoreBluetooth support.")
        print("   Usage: shearwater-cli <file_path>")
        exit(1)
        #endif
    }

    await main()
