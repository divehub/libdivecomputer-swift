import Foundation

/// Default BLE UUIDs used by Shearwater for their proprietary serial service.
/// These are widely used across Perdix/Petrel/Teric/Nerd/Peregrine generations.
public enum ShearwaterBLE {
    public static let service = BluetoothUUID("fe25c237-0ece-443c-b0aa-e02033e7029d")
}

public struct ShearwaterDescriptor {
    public static func makeDefault() -> DiveComputerDescriptor {
        let service = BluetoothServiceConfiguration(
            service: ShearwaterBLE.service,
            characteristics: [:]  // Empty - will discover dynamically
        )
        return DiveComputerDescriptor(
            vendor: "Shearwater",
            product: "Perdix/Petrel/Teric series",
            capabilities: [.logDownload, .firmwareInfo, .liveTelemetry],
            services: [service],
            maximumMTU: 244
        )
    }
}

public final class ShearwaterDriver: DiveComputerDriver {
    public let descriptor: DiveComputerDescriptor

    public init(descriptor: DiveComputerDescriptor = ShearwaterDescriptor.makeDefault()) {
        self.descriptor = descriptor
    }

    @MainActor
    public func open(link: BluetoothLink) async throws -> any DiveComputerDriverSession {
        print("🔧 ShearwaterDriver: Finding characteristics dynamically...")

        // First, list all discovered characteristics
        let allChars = try await link.getDiscoveredCharacteristics(for: ShearwaterBLE.service)
        print("🔧 ShearwaterDriver: Total characteristics discovered: \(allChars.count)")
        for char in allChars {
            print("  - \(char.characteristic)")
        }

        // Get write characteristic (has .write or .writeWithoutResponse property)
        guard let writeChar = try await link.getWriteCharacteristic(for: ShearwaterBLE.service)
        else {
            print("❌ ShearwaterDriver: No write characteristic found")
            throw BluetoothTransportError.missingCharacteristic(
                BluetoothCharacteristic(
                    service: ShearwaterBLE.service, characteristic: BluetoothUUID("unknown"))
            )
        }

        // Get notify characteristic (has .notify or .indicate property)
        guard let notifyChar = try await link.getNotifyCharacteristic(for: ShearwaterBLE.service)
        else {
            print("❌ ShearwaterDriver: No notify characteristic found")
            throw BluetoothTransportError.missingCharacteristic(
                BluetoothCharacteristic(
                    service: ShearwaterBLE.service, characteristic: BluetoothUUID("unknown"))
            )
        }

        print("✅ ShearwaterDriver: Write char: \(writeChar.characteristic)")
        print("✅ ShearwaterDriver: Notify char: \(notifyChar.characteristic)")

        // Determine the appropriate write type for this characteristic
        let writeType = try await link.getWriteType(for: writeChar)
        print(
            "✅ ShearwaterDriver: Write type: \(writeType == .withResponse ? "withResponse" : "withoutResponse")"
        )

        // Enable notifications before starting communication
        print("🔧 ShearwaterDriver: Enabling notifications...")
        try await link.enableNotifications(for: notifyChar)
        print("✅ ShearwaterDriver: Notifications enabled, ready to communicate")

        let transport = ShearwaterTransport(
            link: link,
            commandCharacteristic: writeChar,
            notifyCharacteristic: notifyChar,
            writeType: writeType
        )

        // Wait for notification consumer to be ready
        await transport.waitForReady()

        let session = ShearwaterSession(
            descriptor: descriptor,
            transport: transport
        )
        return session
    }
}

@MainActor
public final class ShearwaterSession: @unchecked Sendable, DiveComputerDriverSession {
    private let descriptor: DiveComputerDescriptor
    private let transport: ShearwaterTransport

    internal init(descriptor: DiveComputerDescriptor, transport: ShearwaterTransport) {
        self.descriptor = descriptor
        self.transport = transport
    }

    public func readDeviceInfo() async throws -> DiveComputerInfo {
        let serialHex = try await transport.readDBI(id: 0x8010, expected: 8)
        let firmwareBytes = try await transport.readDBI(
            id: 0x8011, expected: 12, allowShorter: true)
        let hardwareBytes = try await transport.readDBI(id: 0x8050, expected: 2)

        let serialString =
            String(data: serialHex, encoding: .ascii)
            ?? serialHex.map { String(format: "%02X", $0) }.joined()
        let firmwareString = String(data: firmwareBytes, encoding: .ascii)
        let hardware = UInt16(bigEndian: hardwareBytes.withUnsafeBytes { $0.load(as: UInt16.self) })
        let modelName = ShearwaterModelMapper.modelName(for: hardware)

        return DiveComputerInfo(
            serialNumber: serialString,
            firmwareVersion: firmwareString,
            hardwareVersion: String(format: "0x%04X", hardware),
            vendor: descriptor.vendor,
            model: modelName
        )
    }



    private struct DiveCandidate {
        let index: Int
        let address: UInt32
        let fingerprint: Data
    }

    // Protocol Conformance
    public func downloadDiveLogs(progress: DiveDownloadProgress?) async throws -> [DiveLog] {
        try await downloadDiveLogs(fingerprint: nil, progress: progress, onRawData: nil)
    }

    public func downloadDiveLogs(
        fingerprint: Data? = nil,
        progress: DiveDownloadProgress?,
        onRawData: ((Int, Data) -> Void)? = nil
    ) async throws -> [DiveLog] {
        // 1. Read Log Parameters
        let logUpload = try await transport.readDBI(id: 0x8021, expected: 9)
        var baseAddr = logUpload[1...4].reduce(0) { ($0 << 8) | UInt32($1) }
        switch baseAddr {
        case 0xDD00_0000, 0xC000_0000, 0x9000_0000:
            baseAddr = 0xC000_0000
        case 0x8000_0000:
            break
        default:
            break
        }
        
        // 2. Download and Parse Manifest (List First)
        let candidates = try await downloadManifest()
        
        // 3. Log Candidates
        print("📋 Manifest parsed. Found \(candidates.count) dives:")
        for candidate in candidates {
            print("   Dive #\(candidate.index): Addr=0x\(String(format: "%0X", candidate.address)) Fingerprint=\(candidate.fingerprint.map { String(format: "%02X", $0) }.joined())")
        }
        
        // 4. Download Dives
        return try await downloadDives(
            candidates: candidates,
            baseAddr: baseAddr,
            syncFingerprint: fingerprint,
            progress: progress,
            onRawData: onRawData
        )
    }
    
    private func downloadManifest() async throws -> [DiveCandidate] {
        let manifestAddr: UInt32 = 0xE000_0000
        let manifestSize = 0x600
        let recordSize = 0x20
        
        print("📋 Downloading manifest...")
        let manifestData = try await transport.download(
            address: manifestAddr,
            size: manifestSize,
            compressed: false
        ) { _, _ in }
        
        var candidates: [DiveCandidate] = []
        var offset = 0
        var sortedIndex = 1
        
        while offset + recordSize <= manifestData.count {
            let header = UInt16(
                bigEndian: manifestData.withUnsafeBytes { ptr in
                    ptr.load(fromByteOffset: offset, as: UInt16.self)
                })
            
            if header == 0x5A23 {
                offset += recordSize
                continue  // deleted dive
            }
            guard header == 0xA5C4 else { break }
            
            let fingerData = manifestData[offset + 4..<offset + 8]
            let address = manifestData[offset + 20..<offset + 24].reduce(0) {
                ($0 << 8) | UInt32($1)
            }
            
            candidates.append(DiveCandidate(index: sortedIndex, address: address, fingerprint: Data(fingerData)))
            sortedIndex += 1
            offset += recordSize
        }
        
        return candidates
    }

    private func downloadDives(
        candidates: [DiveCandidate],
        baseAddr: UInt32,
        syncFingerprint: Data?,
        progress: DiveDownloadProgress?,
        onRawData: ((Int, Data) -> Void)?
    ) async throws -> [DiveLog] {
        let maxDiveSize = 0xFFFFFF
        var dives: [DiveLog] = []
        
        // Progress: We report "steps" instead of bytes effectively, 
        // or we could use a fixed large number. 
        // User requested "don't estimate", but we need *some* progress reporting.
        // We will report progress per dive.
        let totalDives = candidates.count
        var currentDiveIndex = 0
        
        // If we have a sync fingerprint, we can skip older dives.
        // Assuming candidates are ordered new->old or old->new?
        // Shearwater manifest order is strictly sequential in memory.
        
        for candidate in candidates {
            // Check sync fingerprint
            if let target = syncFingerprint, candidate.fingerprint == target {
                print("✨ Reached previously synced dive (Fingerprint match). Stopping.")
                break
            }
            
            print("⬇️ Downloading Dive #\(candidate.index) (Addr=0x\(String(format: "%0X", candidate.address)))...")
            
            // Short pause between dives to let device settle
            try await Task.sleep(nanoseconds: 200_000_000) // 200ms

            // We pass a dummy progress closure to 'download' because we handle
            // aggregate progress here at the dive level.
            let diveData = try await transport.download(
                address: baseAddr + candidate.address,
                size: maxDiveSize,
                compressed: true
            ) { bytesDone, bytesTotal in
                 // Optional: Could forward detailed byte progress here if needed
            }

            // Report raw data if requested
            onRawData?(candidate.index, diveData)
            
            if let parsed = ShearwaterLogParser.parse(data: diveData) {
                let log = DiveLog(
                    startTime: parsed.startTime,
                    duration: parsed.duration,
                    maxDepthMeters: parsed.maxDepth,
                    averageDepthMeters: parsed.avgDepth,
                    samples: parsed.samples,
                    gasMixes: parsed.gasMixes,
                    notes: parsed.notes,
                    fingerprint: parsed.fingerprint ?? candidate.fingerprint
                )
                dives.append(log)
            } else {
                let log = DiveLog(
                    startTime: Date(),
                    duration: .seconds(0),
                    maxDepthMeters: 0,
                    samples: [],
                    notes: "Failed to parse dive #\(candidate.index)",
                    fingerprint: candidate.fingerprint
                )
                dives.append(log)
            }
            
            currentDiveIndex += 1
            // Use a large constant for 'total' to represent 100% per dive if we wanted,
            // or just report dive count progress.
            // Let's report current byte count roughly or just dive count?
            // The closure expects (completed, total).
            progress?(currentDiveIndex, totalDives)
        }
        
        return dives
    }

    public func liveSamples() -> AsyncThrowingStream<DiveSample, Error>? {
        // Shearwater does not stream continuous live telemetry over the same service in the legacy protocol.
        return nil
    }

    public func close() async {
        // Send End Session command (Shearwater Common Close logic)
        // 0x2E 0x90 0x20 0x00
        print("🔌 ShearwaterSession: Sending End Session command...")
        _ = try? await transport.transfer(request: Data([0x2E, 0x90, 0x20, 0x00]), expected: 0)
        
        // No special shutdown needed; caller will close BluetoothLink.
        await transport.shutdown()
    }
}

@MainActor
final class ShearwaterTransport: @unchecked Sendable {
    private let link: BluetoothLink
    private let commandCharacteristic: BluetoothCharacteristic
    private let notifyCharacteristic: BluetoothCharacteristic
    private let writeType: BluetoothWriteType
    private var receivedData: Data = Data()
    private let dataQueue = DispatchQueue(label: "com.shearwater.dataqueue")
    private var notificationTask: Task<Void, Never>?
    
    // Continuation for waiting for data, replacing polling
    private var dataContinuation: CheckedContinuation<Void, Error>?

    init(
        link: BluetoothLink, commandCharacteristic: BluetoothCharacteristic,
        notifyCharacteristic: BluetoothCharacteristic,
        writeType: BluetoothWriteType
    ) {
        self.link = link
        self.commandCharacteristic = commandCharacteristic
        self.notifyCharacteristic = notifyCharacteristic
        self.writeType = writeType

        // Start background task that continuously buffers notifications
        self.notificationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let stream = self.link.notifications(for: notifyCharacteristic)
            var totalChunks = 0
            do {
                for try await chunk in stream {
                    totalChunks += 1
                    self.dataQueue.sync {
                        self.receivedData.append(chunk)
                    }
                    // Resume any waiter
                    if let continuation = self.dataContinuation {
                        self.dataContinuation = nil
                        continuation.resume()
                    }
                }
                print("📭 Notification stream ended normally after \(totalChunks) chunks")
            } catch {
                print("📭 Notification stream error after \(totalChunks) chunks: \(error)")
                // Fail any waiter
                if let continuation = self.dataContinuation {
                    self.dataContinuation = nil
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Wait for the notification consumer to be ready
    func waitForReady() async {
        // Give the notification consumer task time to start and set up the stream
        try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
        print("✅ ShearwaterTransport: Ready")
    }
    
    func shutdown() async {
        notificationTask?.cancel()
        dataContinuation?.resume(throwing: ShearwaterError.timeout) // or cancelled
        dataContinuation = nil
    }

    /// Set to true to enable verbose transfer logging
    var verboseLogging = false

    func transfer(request: Data, expected: Int) async throws -> Data {
        if verboseLogging {
            print(
                "📤 ShearwaterTransport: Sending request \(request.map { String(format: "%02x", $0) }.joined()) (\(request.count) bytes), expecting \(expected) bytes response"
            )
        }

        // Clear buffer before sending
        dataQueue.sync {
            if !receivedData.isEmpty {
                if verboseLogging {
                    print("⚠️ ShearwaterTransport: Clearing \(receivedData.count) stale bytes")
                }
                receivedData = Data()
            }
            // Clear any pending continuation to ensure we don't wake up on stale events
            // (though clearing receivedData handles the data part)
        }

        let packet = ShearwaterSlip.buildPacket(payload: request)
        let frames = ShearwaterSlip.encode(packet)

        for frame in frames {
            try await link.write(frame, to: commandCharacteristic, type: writeType)
        }

        if expected == 0 {
            return Data()
        }

        return try await readSlipPacket()
    }

    @MainActor
    private func readSlipPacket() async throws -> Data {
        var output = Data()
        var escaped = false
        var chunkCount = 0
        let startTime = Date()
        let timeout: TimeInterval = 5.0

        while true {
            if Date().timeIntervalSince(startTime) > timeout {
                print("⏰ Timeout after \(chunkCount) chunks, output so far: \(output.count) bytes")
                if output.count > 0 {
                    let preview = output.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " ")
                    print("   Preview: \(preview)")
                }
                throw ShearwaterError.timeout
            }

            var chunk: Data?
            
            // Check for data
            var shouldWait = false
            dataQueue.sync {
                if !receivedData.isEmpty {
                    chunk = receivedData
                    receivedData = Data()
                } else {
                    shouldWait = true
                }
            }
            
            if shouldWait {
                // Wait for notification
                try await withCheckedThrowingContinuation { continuation in
                    self.dataContinuation = continuation
                }
                // Loop around to pick up data
                continue
            }

            if let chunk = chunk {
                chunkCount += 1

                // Skip 2-byte frame header
                let body = chunk.count >= 2 ? Array(chunk.dropFirst(2)) : Array(chunk)

                for byte in body {
                    if byte == ShearwaterSlip.END {
                        if !output.isEmpty {
                            return try ShearwaterSlip.validateAndStripHeader(packet: output)
                        }
                        continue
                    } else if byte == ShearwaterSlip.ESC {
                        escaped = true
                        continue
                    }

                    var value = byte
                    if escaped {
                        if byte == ShearwaterSlip.ESC_END {
                            value = ShearwaterSlip.END
                        } else if byte == ShearwaterSlip.ESC_ESC {
                            value = ShearwaterSlip.ESC
                        }
                        escaped = false
                    }
                    output.append(value)
                }
            }
        }
    }

    func readDBI(id: UInt16, expected: Int, allowShorter: Bool = false) async throws -> Data {
        let request = Data([0x22, UInt8(id >> 8), UInt8(id & 0xFF)])
        let response = try await transfer(request: request, expected: expected + 3)
        guard response.count >= 3, response[0] == 0x62, response[1] == request[1],
            response[2] == request[2]
        else {
            throw ShearwaterError.unexpectedRDBIResponse(id: id)
        }
        let payload = response.dropFirst(3)
        if !allowShorter && payload.count != expected {
            throw ShearwaterError.invalidRDBIPayloadLength(expected: expected, got: payload.count)
        }
        return Data(payload)
    }

    func download(
        address: UInt32, size: Int, compressed: Bool, progress: @escaping (Int, Int) -> Void
    ) async throws -> Data {
        // Init request: 0x35 flags(0x10 if compressed) 0x34 address(4) size(3)
        var request = Data([0x35, compressed ? 0x10 : 0x00, 0x34])
        request.append(contentsOf: [
            UInt8((address >> 24) & 0xFF),
            UInt8((address >> 16) & 0xFF),
            UInt8((address >> 8) & 0xFF),
            UInt8(address & 0xFF),
            UInt8((UInt32(size) >> 16) & 0xFF),
            UInt8((UInt32(size) >> 8) & 0xFF),
            UInt8(UInt32(size) & 0xFF),
        ])

        var initResp = try await transfer(request: request, expected: 3)

        // If we get 0x7F (error/NAK), the device might be in a bad state from a previous
        // incomplete transfer. Send a quit command to reset, then retry the init.
        if initResp.count >= 1 && initResp[0] == 0x7F {
            print("⚠️ Got NAK on init, sending quit to reset device state...")
            _ = try? await transfer(request: Data([0x37]), expected: 2)
            try await Task.sleep(nanoseconds: 100_000_000)  // 100ms delay
            initResp = try await transfer(request: request, expected: 3)
        }

        guard initResp.count >= 3, initResp[0] == 0x75 else {
            throw ShearwaterError.unexpectedInitResponse(
                expected: 0x75, got: initResp.count >= 1 ? initResp[0] : 0)
        }

        progress(3, size)

        // Give the device a moment to prepare for block transmission
        // This is crucial for switching to compressed mode or just processing the init
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms

        var blockIndex: UInt8 = 1
        var totalReceived = 0
        var output = Data()
        let maxBlock = Int(initResp[2])
        print("📦 Download started: maxBlock=\(maxBlock), size=\(size), initResp=\(initResp.map { String(format: "%02x", $0) }.joined())")

        while totalReceived < size {
            // Check for cancellation
            try Task.checkCancellation()

            let blockReq = Data([0x36, blockIndex])
            let blockResp: Data
            do {
                blockResp = try await transfer(request: blockReq, expected: maxBlock + 2)
            } catch {
                print("❌ Block \(blockIndex) transfer failed: \(error)")
                throw error
            }
            guard blockResp.count >= 2, blockResp[0] == 0x76, blockResp[1] == blockIndex else {
                let got = blockResp.count >= 2 ? blockResp[1] : 0
                print(
                    "❌ Block response mismatch: expected 0x76 idx=\(blockIndex), got 0x\(String(format: "%02X", blockResp[0])) idx=\(got)"
                )
                throw ShearwaterError.unexpectedBlockResponse(
                    expectedIndex: blockIndex, gotIndex: got)
            }

            let payload = Data(blockResp.dropFirst(2))  // Convert to Data to reset indices to 0
            totalReceived += payload.count
            progress(totalReceived, size)

            if compressed {
                let (expanded, isFinal) = try ShearwaterDecompressor.decompressLRE(payload)
                output.append(expanded)
                if isFinal {
                    break
                }
            } else {
                output.append(contentsOf: payload)
            }

            blockIndex &+= 1
        }

        if compressed {
            output = ShearwaterDecompressor.decompressXOR(output)
        }

        // Send quit command - don't fail if response is unexpected, just log it
        // The 0x37 (quit) command should respond with 0x77 0x00 on success
        // but may return 0x7F (negative response) if session already ended
        let quitResp = try await transfer(request: Data([0x37]), expected: 2)
        if quitResp.count != 2 || quitResp[0] != 0x77 || quitResp[1] != 0x00 {
            print(
                "⚠️ Quit response unexpected: \(quitResp.map { String(format: "%02x", $0) }.joined())"
            )
            // Don't throw - we got the data, just the quit confirmation failed
        }

        return output
    }
}


private enum ShearwaterSlip {
    static let END: UInt8 = 0xC0
    static let ESC: UInt8 = 0xDB
    static let ESC_END: UInt8 = 0xDC
    static let ESC_ESC: UInt8 = 0xDD

    static func buildPacket(payload: Data) -> Data {
        var packet = Data()
        packet.append(0xFF)
        packet.append(0x01)
        packet.append(UInt8(payload.count + 1))
        packet.append(0x00)
        packet.append(contentsOf: payload)
        return packet
    }

    static func encode(_ data: Data) -> [Data] {
        // Determine total encoded size to compute frame count.
        var count = 1  // END
        for byte in data {
            if byte == END || byte == ESC {
                count += 2
            } else {
                count += 1
            }
        }
        let frameSize = 32
        let payloadCapacity = frameSize - 2
        let nframes = (count + payloadCapacity - 1) / payloadCapacity

        var frames: [Data] = []
        var buffer = Data()

        func flush() {
            guard !buffer.isEmpty else { return }
            // First byte is total frame count, second byte is current frame index (0-based)
            var frame = Data([UInt8(nframes), UInt8(frames.count)])
            frame.append(buffer)
            frames.append(frame)
            buffer = Data()
        }

        for byte in data {
            if byte == END || byte == ESC {
                buffer.append(ESC)
                if buffer.count >= payloadCapacity { flush() }
                buffer.append(byte == END ? ESC_END : ESC_ESC)
            } else {
                buffer.append(byte)
            }
            if buffer.count >= payloadCapacity {
                flush()
            }
        }

        buffer.append(END)
        flush()

        return frames
    }

    static func validateAndStripHeader(packet: Data) throws -> Data {
        guard packet.count >= 4 else {
            throw ShearwaterError.packetTooShort(minimum: 4, actual: packet.count)
        }
        guard packet[0] == 0x01, packet[1] == 0xFF, packet[3] == 0x00 else {
            throw ShearwaterError.invalidPacketHeader
        }
        let length = Int(packet[2])
        guard length >= 1, length - 1 + 4 <= packet.count else {
            throw ShearwaterError.invalidPacketLength(expected: length - 1 + 4, got: packet.count)
        }
        return Data(packet[4..<4 + length - 1])
    }
}

private enum ShearwaterDecompressor {
    static func decompressLRE(_ data: Data) throws -> (Data, Bool) {
        guard !data.isEmpty else {
            return (Data(), true)
        }

        let nbits = data.count * 8
        var offset = 0
        var output = Data()
        var isFinal = false

        while offset + 9 <= nbits {
            let byte = offset / 8
            let bit = offset % 8

            // Extract 9-bit value spanning two bytes
            let shift = 16 - (bit + 9)
            let hi = UInt16(data[byte]) << 8
            let lo: UInt16 = (byte + 1 < data.count) ? UInt16(data[byte + 1]) : 0
            let chunk = hi | lo
            let value = (chunk >> shift) & 0x1FF

            if (value & 0x100) != 0 {
                // High bit set: emit the low 8 bits as a literal byte
                output.append(UInt8(value & 0xFF))
            } else if value == 0 {
                // Zero value: end of data marker
                isFinal = true
                break
            } else {
                // Non-zero without high bit: run of N zeros
                let runLength = min(Int(value), 65536)
                output.append(contentsOf: Array(repeating: UInt8(0), count: runLength))
            }
            offset += 9
        }

        return (output, isFinal)
    }

    static func decompressXOR(_ data: Data) -> Data {
        guard data.count > 32 else { return data }
        var result = data
        for i in 32..<result.count {
            result[i] ^= result[i - 32]
        }
        return result
    }
}

private enum ShearwaterModelMapper {
    static func modelName(for hardware: UInt16) -> String {
        switch hardware {
        case 0x0101, 0x0202:
            return "Predator"
        case 0x0404, 0x0909:
            return "Petrel"
        case 0x0505, 0x0808, 0x0838, 0x08A5, 0x0B0B, 0x7828, 0x7B2C, 0x8838:
            return "Petrel 2"
        case 0xB407:
            return "Petrel 3"
        case 0x0606, 0x0A0A:
            return "Nerd"
        case 0x0E0D, 0x7E2D:
            return "Nerd 2"
        case 0x0707:
            return "Perdix"
        case 0x0C0D, 0x7C2D, 0x8D6C, 0x425B:
            return "Perdix AI"
        case 0x704C, 0xC407, 0xC964, 0x9C64:
            return "Perdix 2"
        case 0x0F0F, 0x1F0A, 0x1F0F:
            return "Teric"
        case 0x1512:
            return "Peregrine"
        case 0x1712, 0x813A:
            return "Peregrine TX"
        case 0xC0E0:
            return "Tern"
        default:
            return String(format: "Unknown(0x%04X)", hardware)
        }
    }
}
