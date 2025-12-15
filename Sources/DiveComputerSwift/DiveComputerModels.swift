import Foundation

public struct DiveComputerInfo: Sendable, Hashable {
    public var serialNumber: String?
    public var firmwareVersion: String?
    public var hardwareVersion: String?
    public var batteryLevel: Double?
    public var lastSync: Date?
    public var vendor: String?
    public var model: String?

    public init(
        serialNumber: String? = nil,
        firmwareVersion: String? = nil,
        hardwareVersion: String? = nil,
        batteryLevel: Double? = nil,
        lastSync: Date? = nil,
        vendor: String? = nil,
        model: String? = nil
    ) {
        self.serialNumber = serialNumber
        self.firmwareVersion = firmwareVersion
        self.hardwareVersion = hardwareVersion
        self.batteryLevel = batteryLevel
        self.lastSync = lastSync
        self.vendor = vendor
        self.model = model
    }
}

public struct GasMix: Sendable, Hashable {
    public var oxygenFraction: Double
    public var heliumFraction: Double
    public var isDiluent: Bool

    public init(oxygenFraction: Double, heliumFraction: Double = 0, isDiluent: Bool = false) {
        self.oxygenFraction = oxygenFraction
        self.heliumFraction = heliumFraction
        self.isDiluent = isDiluent
    }
}

public enum DiveEvent: Sendable, Hashable {
    case gasChange(GasMix)  // Usually OC gas switch
    case diluentChange(GasMix)  // CCR Diluent switch
    case warning(String)
    case error(String)
    case unknown(code: Int)
}

public enum TankUsage: String, Sendable, Hashable, Codable {
    case oxygen
    case diluent
    case sidemount
    case unknown
}

public struct DiveTank: Sendable, Hashable {
    public var name: String?
    public var serialNumber: String?
    public var volumeLiters: Double?
    public var workingPressureBar: Double?
    public var startPressureBar: Double?
    public var endPressureBar: Double?
    public var gasMix: GasMix?
    public var usage: TankUsage

    public init(
        name: String? = nil,
        serialNumber: String? = nil,
        volumeLiters: Double? = nil,
        workingPressureBar: Double? = nil,
        startPressureBar: Double? = nil,
        endPressureBar: Double? = nil,
        gasMix: GasMix? = nil,
        usage: TankUsage = .unknown
    ) {
        self.name = name
        self.serialNumber = serialNumber
        self.volumeLiters = volumeLiters
        self.workingPressureBar = workingPressureBar
        self.startPressureBar = startPressureBar
        self.endPressureBar = endPressureBar
        self.gasMix = gasMix
        self.usage = usage
    }
}

public enum DiveMode: String, Sendable, Hashable, Codable {
    case ccr
    case ocTec
    case ocRec
    case gauge
    case ppo2
    case semiClosed
    case freedive
    case avelo
    case unknown
}

public struct DiveSample: Sendable, Hashable {
    public var timestamp: Date
    public var depthMeters: Double
    public var temperatureCelsius: Double?
    public var tankPressureBar: Double?
    public var ppo2: Double?
    public var setpoint: Double?
    public var cns: Double?
    public var noDecompressionLimit: TimeInterval?
    public var decoCeiling: Double?
    public var decoStopDepth: Double?
    public var decoStopTime: TimeInterval?
    public var events: [DiveEvent]
    public var diveMode: DiveMode?
    public var ppo2Sensors: [Double]?
    public var isExternalPPO2: Bool?
    public var tts: TimeInterval?

    public init(
        timestamp: Date,
        depthMeters: Double,
        temperatureCelsius: Double? = nil,
        tankPressureBar: Double? = nil,
        ppo2: Double? = nil,
        setpoint: Double? = nil,
        cns: Double? = nil,
        noDecompressionLimit: TimeInterval? = nil,
        decoCeiling: Double? = nil,
        decoStopDepth: Double? = nil,
        decoStopTime: TimeInterval? = nil,
        events: [DiveEvent] = [],
        diveMode: DiveMode? = nil,
        ppo2Sensors: [Double]? = nil,
        isExternalPPO2: Bool? = nil,
        tts: TimeInterval? = nil
    ) {
        self.timestamp = timestamp
        self.depthMeters = depthMeters
        self.temperatureCelsius = temperatureCelsius
        self.tankPressureBar = tankPressureBar
        self.ppo2 = ppo2
        self.setpoint = setpoint
        self.cns = cns
        self.noDecompressionLimit = noDecompressionLimit
        self.decoCeiling = decoCeiling
        self.decoStopDepth = decoStopDepth
        self.decoStopTime = decoStopTime
        self.events = events
        self.diveMode = diveMode
        self.ppo2Sensors = ppo2Sensors
        self.isExternalPPO2 = isExternalPPO2
        self.tts = tts
    }
}

public struct DiveLog: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var startTime: Date
    public var duration: Duration
    public var maxDepthMeters: Double
    public var averageDepthMeters: Double?
    public var waterTemperatureCelsius: Double?
    public var surfacePressure: Double?
    public var samples: [DiveSample]
    public var gasMixes: [GasMix]
    public var fingerprint: String?
    public var tanks: [DiveTank]
    public var decoModel: String?
    public var gradientFactorLow: Int?
    public var gradientFactorHigh: Int?
    public var diveMode: DiveMode?
    public var waterDensity: Double?
    public var timeZoneOffset: TimeInterval?

    public var rawData: Data?

    public init(
        id: UUID = UUID(),
        startTime: Date,
        duration: Duration,
        maxDepthMeters: Double,
        averageDepthMeters: Double? = nil,
        waterTemperatureCelsius: Double? = nil,
        surfacePressureBar: Double? = nil,
        samples: [DiveSample] = [],
        gasMixes: [GasMix] = [],
        tanks: [DiveTank] = [],
        decoModel: String? = nil,
        gradientFactorLow: Int? = nil,
        gradientFactorHigh: Int? = nil,
        diveMode: DiveMode? = nil,
        waterDensity: Double? = nil,
        timeZoneOffset: TimeInterval? = nil,
        fingerprint: String? = nil,
        rawData: Data? = nil
    ) {
        self.id = id
        self.startTime = startTime
        self.duration = duration
        self.maxDepthMeters = maxDepthMeters
        self.averageDepthMeters = averageDepthMeters
        self.waterTemperatureCelsius = waterTemperatureCelsius
        self.surfacePressure = surfacePressureBar
        self.samples = samples
        self.gasMixes = gasMixes
        self.tanks = tanks
        self.decoModel = decoModel
        self.gradientFactorLow = gradientFactorLow
        self.gradientFactorHigh = gradientFactorHigh
        self.diveMode = diveMode
        self.waterDensity = waterDensity
        self.timeZoneOffset = timeZoneOffset
        self.fingerprint = fingerprint
        self.rawData = rawData
    }
}
