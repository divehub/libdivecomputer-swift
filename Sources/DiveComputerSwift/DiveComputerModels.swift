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
    /// Fractional O2 content in range 0.0...1.0
    public var o2: Double
    /// Fractional He content in range 0.0...1.0
    public var he: Double
    public var isDiluent: Bool

    public init(o2: Double, he: Double = 0, isDiluent: Bool = false) {
        self.o2 = o2
        self.he = he
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

public struct DiveTank: Sendable, Hashable {
    public struct PressureRecord: Sendable, Hashable {
        public var timestamp: Date
        public var pressureBar: Double

        public init(timestamp: Date, pressureBar: Double) {
            self.timestamp = timestamp
            self.pressureBar = pressureBar
        }
    }

    public var name: String?
    public var sensorId: String?
    public var volumeLiters: Double?
    public var startPressureBar: Double?
    public var endPressureBar: Double?
    public var pressureRecords: [PressureRecord]

    public init(
        name: String? = nil,
        sensorId: String? = nil,
        volumeLiters: Double? = nil,
        startPressureBar: Double? = nil,
        endPressureBar: Double? = nil,
        pressureRecords: [PressureRecord] = []
    ) {
        self.name = name
        self.sensorId = sensorId
        self.volumeLiters = volumeLiters
        self.startPressureBar = startPressureBar
        self.endPressureBar = endPressureBar
        self.pressureRecords = pressureRecords
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
    public var ppo2: Double?
    public var setpoint: Double?
    public var cns: Double?
    public var noDecompressionLimit: TimeInterval?
    public var decoCeiling: Double?  // not available on certain devices. They may use decoStopDepth
    public var decoStopDepth: Double?
    public var decoStopTime: TimeInterval?
    /// Active gas mix at this sample (fractions are 0.0...1.0).
    public var gasMix: GasMix?
    public var events: [DiveEvent]
    public var diveMode: DiveMode?
    public var ppo2Sensors: [Double]?
    public var isExternalPPO2: Bool?  // uses external PPo2 sensors. Which usually means ppo2Sensors are available.
    public var tts: TimeInterval?

    public init(
        timestamp: Date,
        depthMeters: Double,
        temperatureCelsius: Double? = nil,
        ppo2: Double? = nil,
        setpoint: Double? = nil,
        cns: Double? = nil,
        noDecompressionLimit: TimeInterval? = nil,
        decoCeiling: Double? = nil,
        decoStopDepth: Double? = nil,
        decoStopTime: TimeInterval? = nil,
        gasMix: GasMix? = nil,
        events: [DiveEvent] = [],
        diveMode: DiveMode? = nil,
        ppo2Sensors: [Double]? = nil,
        isExternalPPO2: Bool? = nil,
        tts: TimeInterval? = nil
    ) {
        self.timestamp = timestamp
        self.depthMeters = depthMeters
        self.temperatureCelsius = temperatureCelsius
        self.ppo2 = ppo2
        self.setpoint = setpoint
        self.cns = cns
        self.noDecompressionLimit = noDecompressionLimit
        self.decoCeiling = decoCeiling
        self.decoStopDepth = decoStopDepth
        self.decoStopTime = decoStopTime
        self.gasMix = gasMix
        self.events = events
        self.diveMode = diveMode
        self.ppo2Sensors = ppo2Sensors
        self.isExternalPPO2 = isExternalPPO2
        self.tts = tts
    }
}

/// Format of the dive log raw data, used to determine which parser to use
public enum DiveLogFormat: String, Sendable, Hashable, Codable {
    case shearwater  // Shearwater Petrel Native Format (binary)
    case yaml  // YAML simulated device format
    case garmin_fit  // Garmin FIT dive log format
    case generic  // Generic/unknown format
}

public struct DiveLog: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var startTimeUTC: Date
    public var startTimeLocal: Date
    public var startPositionLat: Double?
    public var startPositionLong: Double?
    public var endPositionLat: Double?
    public var endPositionLong: Double?
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
    public var format: DiveLogFormat
    public var ppo2SensorCalibrations: [Double]?  // Calibration values for PPo2 sensors, if available. cal * mV = ppo2 in bar

    public var rawData: Data?

    public init(
        id: UUID = UUID(),
        startTimeUTC: Date,
        startTimeLocal: Date? = nil,
        startPositionLat: Double? = nil,
        startPositionLong: Double? = nil,
        endPositionLat: Double? = nil,
        endPositionLong: Double? = nil,
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
        fingerprint: String? = nil,
        ppo2SensorCalibrations: [Double]? = nil,
        rawData: Data? = nil,
        format: DiveLogFormat,
    ) {
        self.id = id
        self.startTimeUTC = startTimeUTC
        self.startTimeLocal = startTimeLocal ?? startTimeUTC
        self.startPositionLat = startPositionLat
        self.startPositionLong = startPositionLong
        self.endPositionLat = endPositionLat
        self.endPositionLong = endPositionLong
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
        self.fingerprint = fingerprint
        self.ppo2SensorCalibrations = ppo2SensorCalibrations
        self.rawData = rawData
        self.format = format
    }
}
