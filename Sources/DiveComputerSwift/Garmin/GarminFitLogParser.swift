import Foundation
import ObjcFIT
import SwiftFIT

public enum GarminFitDecodeError: Error, LocalizedError {
    case decodeFailed
    case noRecords

    public var errorDescription: String? {
        switch self {
        case .decodeFailed:
            return "Failed to decode FIT file."
        case .noRecords:
            return "FIT file contains no dive records."
        }
    }
}

public struct GarminFitLogParser {
    public init() {}

    public func parse(fileURL: URL, fingerprint: String? = nil) throws -> DiveLog {
        let data = try Data(contentsOf: fileURL)
        return try parse(data: data, fileURL: fileURL, fingerprint: fingerprint)
    }

    public func parse(data: Data, fingerprint: String? = nil) throws -> DiveLog {
        return try parse(data: data, fileURL: nil, fingerprint: fingerprint)
    }

    private func parse(data: Data, fileURL: URL?, fingerprint: String?) throws -> DiveLog {
        let tempURL = try writeTempIfNeeded(data: data, sourceURL: fileURL)
        defer {
            if fileURL == nil {
                try? FileManager.default.removeItem(at: tempURL)
            }
        }

        let messages = try decodeMessages(at: tempURL)
        let diveLog = mapFitToDiveLog(
            messages: messages,
            rawData: data,
            fingerprint: fingerprint
        )

        return diveLog
    }
}

private func decodeMessages(at url: URL) throws -> FITMessages {
    let decoder = FITDecoder()
    let listener = FITListener()
    decoder.mesgDelegate = listener

    guard decoder.decodeFile(url.path) else {
        throw GarminFitDecodeError.decodeFailed
    }

    return listener.messages
}

private func mapFitToDiveLog(
    messages: FITMessages,
    rawData: Data,
    fingerprint: String?
) -> DiveLog {
    let recordMesgs = messages.getRecordMesgs()
    guard !recordMesgs.isEmpty else {
        return DiveLog(
            startTimeUTC: Date(timeIntervalSince1970: 0),
            duration: .seconds(0),
            maxDepthMeters: 0,
            averageDepthMeters: nil,
            waterTemperatureCelsius: nil,
            surfacePressureBar: nil,
            samples: [],
            gasMixes: [],
            tanks: [],
            decoModel: nil,
            gradientFactorLow: nil,
            gradientFactorHigh: nil,
            diveMode: nil,
            waterDensity: nil,
            fingerprint: fingerprint,
            rawData: rawData,
            format: .garmin_fit
        )
    }

    let activityMesg = messages.getActivityMesgs().first
    let sessionMesg = messages.getSessionMesgs().first
    let diveSummary = messages.getDiveSummaryMesgs().first
    let diveSettingsMesg = messages.getDiveSettingsMesgs().first

    let startTimeUTC = resolvedStartTime(
        activity: activityMesg, session: sessionMesg, records: recordMesgs)
    let startTimeLocal = resolvedStartTimeLocal(activity: activityMesg, records: recordMesgs)
    let durationSeconds = resolvedDuration(session: sessionMesg, records: recordMesgs)
    let maxDepth = resolvedMaxDepth(
        summary: diveSummary, session: sessionMesg, records: recordMesgs)
    let avgDepth = resolvedAvgDepth(
        summary: diveSummary, session: sessionMesg, records: recordMesgs)
    let waterTemperature = resolvedWaterTemperature(session: sessionMesg, records: recordMesgs)
    let startPosition = resolvedStartPosition(session: sessionMesg, records: recordMesgs)
    let endPosition = resolvedEndPosition(session: sessionMesg, records: recordMesgs)

    let decoModel: String? = {
        guard let diveSettingsMesg, diveSettingsMesg.isModelValid() else { return nil }
        return String(describing: diveSettingsMesg.getModel())
    }()

    let gfLow: Int? = {
        guard let diveSettingsMesg, diveSettingsMesg.isGfLowValid() else { return nil }
        return Int(diveSettingsMesg.getGfLow())
    }()

    let gfHigh: Int? = {
        guard let diveSettingsMesg, diveSettingsMesg.isGfHighValid() else { return nil }
        return Int(diveSettingsMesg.getGfHigh())
    }()

    let waterDensity: Double? = {
        guard let diveSettingsMesg, diveSettingsMesg.isWaterDensityValid() else { return nil }
        return Double(diveSettingsMesg.getWaterDensity())
    }()

    let lowSetpoint: Double? = {
        guard let diveSettingsMesg, diveSettingsMesg.isCcrLowSetpointValid() else { return nil }
        return Double(diveSettingsMesg.getCcrLowSetpoint())
    }()

    let highSetpoint: Double? = {
        guard let diveSettingsMesg, diveSettingsMesg.isCcrHighSetpointValid() else { return nil }
        return Double(diveSettingsMesg.getCcrHighSetpoint())
    }()

    let diveMode: DiveMode? = {
        if let diveSettingsMesg,
            diveSettingsMesg.isCcrLowSetpointValid()
                || diveSettingsMesg.isCcrHighSetpointValid()
        {
            return .ccr
        }
        if recordMesgs.contains(where: { $0.isPo2Valid() }) {
            return .ccr
        }
        return nil
    }()

    let gasMixesByIndex = buildGasMixesByIndex(messages.getDiveGasMesgs())
    let gasMixes =
        gasMixesByIndex
        .sorted { $0.key < $1.key }
        .map { $0.value }

    let eventMesgs = messages.getEventMesgs()
    let gasSwitchEvents = buildGasSwitchEvents(eventMesgs: eventMesgs)
    let modeSwitchEvents = buildModeSwitchEvents(eventMesgs: eventMesgs)
    let setpointSwitchEvents = buildSetpointSwitchEvents(
        eventMesgs: eventMesgs,
        lowSetpoint: lowSetpoint,
        highSetpoint: highSetpoint
    )

    let sortedRecords =
        recordMesgs
        .filter { $0.isTimestampValid() && $0.isDepthValid() }
        .sorted { $0.getTimestamp().date < $1.getTimestamp().date }

    var gasSwitchIndex = 0
    var modeSwitchIndex = 0
    var setpointSwitchIndex = 0
    var currentGasMix: GasMix? = initialGasMix(
        gasSwitchEvents: gasSwitchEvents,
        gasMixesByIndex: gasMixesByIndex
    )
    var currentDiveMode = diveMode
    var currentSetpoint = lowSetpoint
    var samples: [DiveSample] = []
    samples.reserveCapacity(sortedRecords.count)

    for record in sortedRecords {
        let timestamp = record.getTimestamp().date

        while gasSwitchIndex < gasSwitchEvents.count,
            gasSwitchEvents[gasSwitchIndex].timestamp <= timestamp
        {
            let gasIndex = gasSwitchEvents[gasSwitchIndex].gasIndex
            if let mix = gasMixesByIndex[gasIndex] {
                currentGasMix = mix
            }
            gasSwitchIndex += 1
        }

        while modeSwitchIndex < modeSwitchEvents.count,
            modeSwitchEvents[modeSwitchIndex].timestamp <= timestamp
        {
            currentDiveMode = modeSwitchEvents[modeSwitchIndex].mode
            modeSwitchIndex += 1
        }

        while setpointSwitchIndex < setpointSwitchEvents.count,
            setpointSwitchEvents[setpointSwitchIndex].timestamp <= timestamp
        {
            currentSetpoint = setpointSwitchEvents[setpointSwitchIndex].setpoint
            setpointSwitchIndex += 1
        }

        let depth = Double(record.getDepth())
        let temperature = record.isTemperatureValid() ? Double(record.getTemperature()) : nil
        let ppo2 = record.isPo2Valid() ? Double(record.getPo2()) : nil
        let cnsLoad = record.isCnsLoadValid() ? Double(record.getCnsLoad()) : nil
        let ndlTime = record.isNdlTimeValid() ? TimeInterval(record.getNdlTime()) : nil
        let nextStopDepth =
            record.isNextStopDepthValid()
            ? Double(record.getNextStopDepth())
            : nil
        let nextStopTime =
            record.isNextStopTimeValid()
            ? TimeInterval(record.getNextStopTime())
            : nil
        let timeToSurface =
            record.isTimeToSurfaceValid()
            ? TimeInterval(record.getTimeToSurface())
            : nil
        let sampleSetpoint =
            (currentDiveMode == .ccr || currentDiveMode == .semiClosed) ? currentSetpoint : nil

        samples.append(
            DiveSample(
                timestamp: timestamp,
                depthMeters: depth,
                temperatureCelsius: temperature,
                ppo2: ppo2,
                setpoint: sampleSetpoint,
                cns: cnsLoad,
                noDecompressionLimit: ndlTime,
                decoCeiling: nextStopDepth,
                decoStopDepth: nextStopDepth,
                decoStopTime: nextStopTime,
                gasMix: currentGasMix,
                diveMode: currentDiveMode,
                isExternalPPO2: false,
                tts: timeToSurface
            )
        )
    }

    let tanks = buildTanks(
        tankUpdateMesgs: messages.getTankUpdateMesgs(),
        tankSummaryMesgs: messages.getTankSummaryMesgs(),
        startTimeUTC: startTimeUTC,
        durationSeconds: durationSeconds
    )

    return DiveLog(
        startTimeUTC: startTimeUTC,
        startTimeLocal: startTimeLocal,
        startPositionLat: startPosition.lat,
        startPositionLong: startPosition.long,
        endPositionLat: endPosition.lat,
        endPositionLong: endPosition.long,
        duration: Duration.seconds(durationSeconds),
        maxDepthMeters: maxDepth,
        averageDepthMeters: avgDepth,
        waterTemperatureCelsius: waterTemperature,
        surfacePressureBar: nil,
        samples: samples,
        gasMixes: gasMixes,
        tanks: tanks,
        decoModel: decoModel,
        gradientFactorLow: gfLow,
        gradientFactorHigh: gfHigh,
        diveMode: diveMode,
        waterDensity: waterDensity,
        fingerprint: fingerprint,
        rawData: rawData,
        format: .garmin_fit
    )
}

private struct GarminGasSwitchEvent {
    let timestamp: Date
    let gasIndex: Int
}

private struct GarminModeSwitchEvent {
    let timestamp: Date
    let mode: DiveMode
}

private struct GarminSetpointSwitchEvent {
    let timestamp: Date
    let setpoint: Double
}

private func buildTanks(
    tankUpdateMesgs: [FITTankUpdateMesg],
    tankSummaryMesgs: [FITTankSummaryMesg],
    startTimeUTC: Date,
    durationSeconds: Double
) -> [DiveTank] {
    var tanksBySensor: [String: DiveTank] = [:]
    var orderedSensors: [String] = []

    func register(_ sensorId: String) {
        if !orderedSensors.contains(sensorId) {
            orderedSensors.append(sensorId)
        }
    }

    func sensorIdString(_ sensor: FITAntChannelId) -> String {
        String(describing: sensor)
    }

    for mesg in tankUpdateMesgs {
        guard mesg.isSensorValid(),
            mesg.isTimestampValid(),
            mesg.isPressureValid()
        else { continue }
        let sensorId = sensorIdString(mesg.getSensor())
        var tank = tanksBySensor[sensorId] ?? DiveTank(sensorId: sensorId)
        tank.pressureRecords.append(
            DiveTank.PressureRecord(
                timestamp: mesg.getTimestamp().date,
                pressureBar: Double(mesg.getPressure())
            )
        )
        tanksBySensor[sensorId] = tank
        register(sensorId)
    }

    for mesg in tankSummaryMesgs {
        guard mesg.isSensorValid() else { continue }
        let sensorId = sensorIdString(mesg.getSensor())
        var tank = tanksBySensor[sensorId] ?? DiveTank(sensorId: sensorId)
        let startPressure =
            mesg.isStartPressureValid() ? Double(mesg.getStartPressure()) : nil
        let endPressure =
            mesg.isEndPressureValid() ? Double(mesg.getEndPressure()) : nil

        if tank.startPressureBar == nil {
            tank.startPressureBar = startPressure
        }
        if tank.endPressureBar == nil {
            tank.endPressureBar = endPressure
        }

        if tank.pressureRecords.isEmpty {
            if let startPressure {
                tank.pressureRecords.append(
                    DiveTank.PressureRecord(
                        timestamp: startTimeUTC,
                        pressureBar: startPressure
                    )
                )
            }
            if let endPressure {
                tank.pressureRecords.append(
                    DiveTank.PressureRecord(
                        timestamp: startTimeUTC.addingTimeInterval(durationSeconds),
                        pressureBar: endPressure
                    )
                )
            }
        }

        tanksBySensor[sensorId] = tank
        register(sensorId)
    }

    for key in orderedSensors {
        guard var tank = tanksBySensor[key] else { continue }
        if tank.startPressureBar == nil, let first = tank.pressureRecords.first {
            tank.startPressureBar = first.pressureBar
            tanksBySensor[key] = tank
        }
        if tank.endPressureBar == nil, let last = tank.pressureRecords.last {
            tank.endPressureBar = last.pressureBar
            tanksBySensor[key] = tank
        }
    }

    return orderedSensors.compactMap { tanksBySensor[$0] }
}

private func buildGasMixesByIndex(_ mesgs: [FITDiveGasMesg]) -> [Int: GasMix] {
    var mixes: [Int: GasMix] = [:]
    for mesg in mesgs {
        guard mesg.isOxygenContentValid() else { continue }
        let oxygen = Double(mesg.getOxygenContent()) / 100.0
        let helium = mesg.isHeliumContentValid() ? Double(mesg.getHeliumContent()) / 100.0 : 0
        let isDiluent =
            mesg.isModeValid()
            && mesg.getMode() == FITDiveGasModeClosedCircuitDiluent
        let index = mesg.isMessageIndexValid() ? Int(mesg.getMessageIndex()) : mixes.count
        mixes[index] = GasMix(o2: oxygen, he: helium, isDiluent: isDiluent)
    }
    return mixes
}

private func buildGasSwitchEvents(eventMesgs: [FITEventMesg]) -> [GarminGasSwitchEvent] {
    eventMesgs.compactMap { mesg in
        guard mesg.isTimestampValid(), mesg.isEventValid(), mesg.isDataValid() else { return nil }
        guard mesg.getEvent() == FITEventDiveGasSwitched else { return nil }
        return GarminGasSwitchEvent(
            timestamp: mesg.getTimestamp().date,
            gasIndex: Int(mesg.getData())
        )
    }
    .sorted { $0.timestamp < $1.timestamp }
}

private func buildModeSwitchEvents(eventMesgs: [FITEventMesg]) -> [GarminModeSwitchEvent] {
    eventMesgs.compactMap { mesg in
        guard mesg.isTimestampValid(), mesg.isEventValid(), mesg.isDataValid() else {
            return nil
        }
        guard mesg.getEvent() == FITEventDiveAlert else { return nil }
        let alertValue = mesg.getData()
        let mode: DiveMode?
        switch alertValue {
        case FITUInt32(FITDiveAlertSwitchedToOpenCircuit):
            mode = .ocTec
        case FITUInt32(FITDiveAlertSwitchedToClosedCircuit):
            mode = .ccr
        default:
            mode = nil
        }
        guard let mode else { return nil }
        return GarminModeSwitchEvent(timestamp: mesg.getTimestamp().date, mode: mode)
    }
    .sorted { $0.timestamp < $1.timestamp }
}

private func buildSetpointSwitchEvents(
    eventMesgs: [FITEventMesg],
    lowSetpoint: Double?,
    highSetpoint: Double?
) -> [GarminSetpointSwitchEvent] {
    eventMesgs.compactMap { mesg in
        guard mesg.isTimestampValid(), mesg.isEventValid(), mesg.isDataValid() else {
            return nil
        }
        guard mesg.getEvent() == FITEventDiveAlert else { return nil }

        let alertValue = mesg.getData()
        let setpoint: Double?
        switch alertValue {
        case FITUInt32(FITDiveAlertSetpointSwitchAutoLow),
            FITUInt32(FITDiveAlertSetpointSwitchManualLow):
            setpoint = lowSetpoint
        case FITUInt32(FITDiveAlertSetpointSwitchAutoHigh),
            FITUInt32(FITDiveAlertSetpointSwitchManualHigh):
            setpoint = highSetpoint
        default:
            setpoint = nil
        }
        guard let setpoint else { return nil }
        return GarminSetpointSwitchEvent(timestamp: mesg.getTimestamp().date, setpoint: setpoint)
    }
    .sorted { $0.timestamp < $1.timestamp }
}

private func initialGasMix(
    gasSwitchEvents: [GarminGasSwitchEvent],
    gasMixesByIndex: [Int: GasMix]
) -> GasMix? {
    if let firstSwitch = gasSwitchEvents.first,
        let mix = gasMixesByIndex[firstSwitch.gasIndex]
    {
        return mix
    }
    return
        gasMixesByIndex
        .sorted { $0.key < $1.key }
        .first?
        .value
}

private func resolvedStartTime(
    activity: FITActivityMesg?, session: FITSessionMesg?, records: [FITRecordMesg]
) -> Date {
    if let activity, activity.isTimestampValid() {
        return activity.getTimestamp().date
    }
    if let session, session.isTimestampValid() {
        return session.getTimestamp().date
    }
    if let firstRecord = records.first, firstRecord.isTimestampValid() {
        return firstRecord.getTimestamp().date
    }
    return Date(timeIntervalSince1970: 0)
}

private func resolvedStartTimeLocal(activity: FITActivityMesg?, records: [FITRecordMesg]) -> Date {
    if let activity, activity.isLocalTimestampValid() {
        let localTimestamp = activity.getLocalTimestamp()
        // FITLocalDateTime is seconds since Garmin epoch (Dec 31, 1989) in local time
        let garminEpoch: TimeInterval = 631_065_600  // seconds from Unix epoch to Garmin epoch
        return Date(timeIntervalSince1970: garminEpoch + TimeInterval(localTimestamp))
    }
    if let firstRecord = records.first, firstRecord.isTimestampValid() {
        return firstRecord.getTimestamp().date
    }
    return Date(timeIntervalSince1970: 0)
}

private struct GarminPosition {
    let lat: Double?
    let long: Double?
}

private func resolvedStartPosition(
    session: FITSessionMesg?,
    records: [FITRecordMesg]
) -> GarminPosition {
    if let session,
        session.isStartPositionLatValid(),
        session.isStartPositionLongValid()
    {
        return GarminPosition(
            lat: semicirclesToDegrees(session.getStartPositionLat()),
            long: semicirclesToDegrees(session.getStartPositionLong())
        )
    }

    let firstRecord =
        records
        .filter { $0.isTimestampValid() && $0.isPositionLatValid() && $0.isPositionLongValid() }
        .sorted { $0.getTimestamp().date < $1.getTimestamp().date }
        .first

    guard let firstRecord else { return GarminPosition(lat: nil, long: nil) }
    return GarminPosition(
        lat: semicirclesToDegrees(firstRecord.getPositionLat()),
        long: semicirclesToDegrees(firstRecord.getPositionLong())
    )
}

private func resolvedEndPosition(
    session: FITSessionMesg?,
    records: [FITRecordMesg]
) -> GarminPosition {
    if let session,
        session.isEndPositionLatValid(),
        session.isEndPositionLongValid()
    {
        return GarminPosition(
            lat: semicirclesToDegrees(session.getEndPositionLat()),
            long: semicirclesToDegrees(session.getEndPositionLong())
        )
    }

    let lastRecord =
        records
        .filter { $0.isTimestampValid() && $0.isPositionLatValid() && $0.isPositionLongValid() }
        .sorted { $0.getTimestamp().date < $1.getTimestamp().date }
        .last

    guard let lastRecord else { return GarminPosition(lat: nil, long: nil) }
    return GarminPosition(
        lat: semicirclesToDegrees(lastRecord.getPositionLat()),
        long: semicirclesToDegrees(lastRecord.getPositionLong())
    )
}

private func semicirclesToDegrees(_ semicircles: FITSInt32) -> Double {
    Double(semicircles) * 180.0 / Double(Int64(1) << 31)
}

private func resolvedDuration(session: FITSessionMesg?, records: [FITRecordMesg]) -> Double {
    if let session, session.isTotalTimerTimeValid() {
        return Double(session.getTotalTimerTime())
    }
    guard
        let first = records.first,
        let last = records.last,
        first.isTimestampValid(),
        last.isTimestampValid()
    else {
        return 0
    }
    return last.getTimestamp().date.timeIntervalSince(first.getTimestamp().date)
}

private func resolvedMaxDepth(
    summary: FITDiveSummaryMesg?, session: FITSessionMesg?, records: [FITRecordMesg]
) -> Double {
    if let summary, summary.isMaxDepthValid() {
        return Double(summary.getMaxDepth())
    }
    if let session, session.isMaxDepthValid() {
        return Double(session.getMaxDepth())
    }
    return records.compactMap { record in
        record.isDepthValid() ? Double(record.getDepth()) : nil
    }.max() ?? 0
}

private func resolvedAvgDepth(
    summary: FITDiveSummaryMesg?, session: FITSessionMesg?, records: [FITRecordMesg]
) -> Double? {
    if let summary, summary.isAvgDepthValid() {
        return Double(summary.getAvgDepth())
    }
    if let session, session.isAvgDepthValid() {
        return Double(session.getAvgDepth())
    }
    let depths = records.compactMap { record -> Double? in
        record.isDepthValid() ? Double(record.getDepth()) : nil
    }
    guard !depths.isEmpty else { return nil }
    let sum = depths.reduce(0, +)
    return sum / Double(depths.count)
}

private func resolvedWaterTemperature(
    session: FITSessionMesg?,
    records: [FITRecordMesg]
) -> Double? {
    if let session, session.isAvgTemperatureValid() {
        return Double(session.getAvgTemperature())
    }
    let temps = records.compactMap { record -> Double? in
        record.isTemperatureValid() ? Double(record.getTemperature()) : nil
    }
    guard !temps.isEmpty else { return nil }
    let sum = temps.reduce(0, +)
    return sum / Double(temps.count)
}

private func writeTempIfNeeded(data: Data, sourceURL: URL?) throws -> URL {
    if let sourceURL { return sourceURL }
    let directory = FileManager.default.temporaryDirectory
    let fileURL = directory.appendingPathComponent("garmin-fit-\(UUID().uuidString).fit")
    try data.write(to: fileURL, options: .atomic)
    return fileURL
}
