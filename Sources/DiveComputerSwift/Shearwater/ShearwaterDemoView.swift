import Foundation

#if canImport(SwiftUI) && canImport(CoreBluetooth)
    import SwiftUI

    @MainActor
    public final class ShearwaterDemoViewModel: ObservableObject {
        @Published public private(set) var discoveries: [BluetoothDiscovery] = []
        @Published public private(set) var isScanning = false
        @Published public private(set) var status: String = "Idle"
        @Published public private(set) var connectedInfo: DiveComputerInfo?
        @Published public private(set) var logs: [DiveLog] = []

        private let manager: DiveComputerManager
        private var scanTask: Task<Void, Never>?

        public init() {
            let transport = CoreBluetoothTransport()
            self.manager = DiveComputerManager(transport: transport)
            self.manager.register(driver: ShearwaterDriver())
        }

        public func startScan(timeout: Duration = .seconds(12)) {
            scanTask?.cancel()
            discoveries = []
            isScanning = true
            status = "Scanning..."
            print("🔍 ShearwaterDemoViewModel: Starting scan with timeout: \(timeout)")

            scanTask = Task {
                do {
                    print("🔍 ShearwaterDemoViewModel: Entering scan loop")
                    for try await device in manager.scan(timeout: timeout) {
                        print(
                            "🔍 ShearwaterDemoViewModel: Received device: \(device.name ?? "Unknown")"
                        )
                        if !discoveries.contains(where: { $0.id == device.id }) {
                            discoveries.append(device)
                        }
                    }
                    status = "Scan completed"
                    print(
                        "🔍 ShearwaterDemoViewModel: Scan completed, found \(discoveries.count) device(s)"
                    )
                } catch {
                    status = "Scan error: \(error.localizedDescription)"
                    print("❌ ShearwaterDemoViewModel: Scan error: \(error)")
                }
                isScanning = false
            }
        }

        public func stopScan() {
            isScanning = false
            scanTask?.cancel()
            manager.stopScan()
            status = "Scan stopped"
        }

        public func connect(to discovery: BluetoothDiscovery) {
            Task {
                do {
                    print(
                        "🔌 ShearwaterDemoViewModel: Connecting to \(discovery.name ?? discovery.descriptor.product)"
                    )
                    status = "Connecting to \(discovery.name ?? discovery.descriptor.product)..."
                    let session = try await manager.connect(to: discovery)
                    print("✅ ShearwaterDemoViewModel: Connected, reading device info...")
                    status = "Reading device info..."
                    let info = try await session.readDeviceInfo()
                    connectedInfo = info
                    print(
                        "✅ ShearwaterDemoViewModel: Device info: \(info.model ?? "unknown") S/N: \(info.serialNumber ?? "unknown")"
                    )
                    status = "Downloading logs..."
                    let pulledLogs = try await session.downloadDiveLogs()
                    logs = pulledLogs
                    print("✅ ShearwaterDemoViewModel: Downloaded \(pulledLogs.count) dive log(s)")
                    status = "Done"
                    await session.close()
                } catch {
                    print("❌ ShearwaterDemoViewModel: Connection error: \(error)")
                    print("❌ Error type: \(type(of: error))")
                    if let btError = error as? BluetoothTransportError {
                        print("❌ BluetoothTransportError: \(btError)")
                    }
                    status = "Error: \(error.localizedDescription)"
                }
            }
        }
    }

    public struct ShearwaterDemoView: View {
        @StateObject private var viewModel = ShearwaterDemoViewModel()

        public init() {}

        public var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Shearwater Demo").font(.title2).bold()
                    Spacer()
                    if viewModel.isScanning {
                        ProgressView()
                    }
                }

                HStack(spacing: 12) {
                    Button(viewModel.isScanning ? "Stop Scan" : "Start Scan") {
                        viewModel.isScanning ? viewModel.stopScan() : viewModel.startScan()
                    }
                    .buttonStyle(.borderedProminent)

                    Text(viewModel.status).font(.subheadline)
                }

                List {
                    Section("Discovered") {
                        if viewModel.discoveries.isEmpty {
                            Text("No devices yet").foregroundColor(.secondary)
                        } else {
                            ForEach(viewModel.discoveries) { device in
                                Button {
                                    viewModel.connect(to: device)
                                } label: {
                                    VStack(alignment: .leading) {
                                        Text(device.name ?? device.descriptor.product)
                                        Text(device.descriptor.vendor)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                    }

                    if let info = viewModel.connectedInfo {
                        Section("Device Info") {
                            infoRow("Model", info.model ?? "")
                            infoRow("Vendor", info.vendor ?? "")
                            infoRow("Serial", info.serialNumber ?? "")
                            infoRow("Firmware", info.firmwareVersion ?? "")
                            if let hw = info.hardwareVersion { infoRow("Hardware", hw) }
                            if let battery = info.batteryLevel {
                                infoRow("Battery", "\(Int(battery * 100))%")
                            }
                        }
                    }

                    if !viewModel.logs.isEmpty {
                        Section("Dive Logs (\(viewModel.logs.count))") {
                            ForEach(viewModel.logs) { log in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(
                                        log.startTime.formatted(
                                            date: .abbreviated, time: .shortened)
                                    )
                                    .font(.headline)
                                    Text(
                                        "Max depth: \(String(format: "%.1f", log.maxDepthMeters)) m"
                                    )
                                    if let avg = log.averageDepthMeters {
                                        Text("Avg depth: \(String(format: "%.1f", avg)) m")
                                    }
                                    Text("Samples: \(log.samples.count)")
                                }
                            }
                        }
                    }
                }
            }
            .padding()
        }

        private func infoRow(_ title: String, _ value: String) -> some View {
            HStack {
                Text(title)
                Spacer()
                Text(value).foregroundColor(.secondary)
            }
        }
    }

#else
    // Fallback placeholder when SwiftUI/CoreBluetooth are unavailable.
    public struct ShearwaterDemoView: View {
        public init() {}
        public var body: some View {
            Text("SwiftUI/CoreBluetooth not available on this platform.")
        }
    }
#endif
