//
//  MixerDomain.swift
//  Qu Controller
//

import Foundation

struct FaderLevel: Equatable {
    let normalized: Double

    init(normalized: Double) {
        self.normalized = normalized.clamped(to: 0 ... 1)
    }

    var percentage: Int {
        Int((normalized * 100).rounded())
    }
}

struct FaderWaveState: Equatable, Codable {
    enum Phase: String, Equatable, Codable {
        case unavailable
        case ready
        case running
        case restoring
        case failed
    }

    let phase: Phase
    let progress: Double
    let message: String

    var isActive: Bool {
        phase == .running || phase == .restoring
    }

    static let disconnected = FaderWaveState(
        phase: .unavailable,
        progress: 0,
        message: "Connect to a mixer to use Fader Wave."
    )

    static func receivingGEQState(receivedBandCount: Int) -> FaderWaveState {
        FaderWaveState(
            phase: .unavailable,
            progress: 0,
            message: "Receiving Main LR GEQ state (\(receivedBandCount)/\(FaderWaveAnimation.bandCount) bands)."
        )
    }

    static let ready = FaderWaveState(
        phase: .ready,
        progress: 0,
        message: "Ready to animate the Main LR GEQ."
    )

    static func running(progress: Double) -> FaderWaveState {
        FaderWaveState(
            phase: .running,
            progress: progress.clamped(to: 0 ... 1),
            message: "Fader Wave is running."
        )
    }

    static let restoring = FaderWaveState(
        phase: .restoring,
        progress: 1,
        message: "Restoring the original GEQ positions."
    )

    static func failed(_ message: String) -> FaderWaveState {
        FaderWaveState(phase: .failed, progress: 0, message: message)
    }
}

enum FaderWaveAnimation {
    static let bandCount = 16
    static let frameInterval: Duration = .milliseconds(150)
    static let frameIntervalSeconds = 0.15

    private static let amplitude = 48.0

    static func frameCount(for configuration: FaderWaveConfiguration) -> Int {
        max(Int((configuration.estimatedDurationSeconds / frameIntervalSeconds).rounded()), 1)
    }

    static func value(
        originalValue: UInt8,
        bandIndex: Int,
        progress: Double,
        configuration: FaderWaveConfiguration
    ) -> UInt8 {
        let boundedProgress = progress.clamped(to: 0 ... 1)
        let envelope = sin(.pi * boundedProgress)
        let bandPosition = Double(bandIndex) / Double(bandCount - 1)
        let phase = 2 * Double.pi * (bandPosition - (boundedProgress * configuration.cycles))
        let offset = sin(phase) * amplitude * envelope
        let animatedValue = (Double(originalValue) + offset).rounded()
        return UInt8(animatedValue.clamped(to: 0 ... 127))
    }
}

struct FaderWaveConfiguration: Equatable, Codable {
    static let cyclesRange = 0.5 ... 5.0
    static let cyclesStep = 0.5
    static let speedRange = 0.5 ... 2.0
    static let speedStep = 0.25
    static let defaultCycles = 1.5
    static let defaultSpeed = 1.0
    static let secondsPerCycleAtNormalSpeed = 8.0

    static let `default` = FaderWaveConfiguration(
        cycles: defaultCycles,
        speed: defaultSpeed
    )

    let cycles: Double
    let speed: Double

    init(cycles: Double, speed: Double) {
        self.cycles = Self.quantized(cycles, step: Self.cyclesStep, range: Self.cyclesRange)
        self.speed = Self.quantized(speed, step: Self.speedStep, range: Self.speedRange)
    }

    var estimatedDurationSeconds: Double {
        cycles * Self.secondsPerCycleAtNormalSpeed / speed
    }

    private static func quantized(
        _ value: Double,
        step: Double,
        range: ClosedRange<Double>
    ) -> Double {
        guard value.isFinite else { return range.lowerBound }
        let clampedValue = value.clamped(to: range)
        return ((clampedValue / step).rounded() * step).clamped(to: range)
    }
}

enum MixerChannelID: String, CaseIterable, Identifiable, Codable {
    case ch1
    case ch2
    case ch3
    case ch4
    case ch5
    case ch6
    case ch7
    case ch8
    case ch9
    case ch10
    case ch11
    case ch12
    case ch13
    case ch14
    case ch15
    case ch16
    case mainLr

    static let selectableChannels: [MixerChannelID] = [
        .ch1, .ch2, .ch3, .ch4, .ch5, .ch6, .ch7, .ch8,
        .ch9, .ch10, .ch11, .ch12, .ch13, .ch14, .ch15, .ch16,
        .mainLr
    ]

    var id: String { rawValue }

    var defaultDisplayName: String {
        switch self {
        case .ch1: "CH 1"
        case .ch2: "CH 2"
        case .ch3: "CH 3"
        case .ch4: "CH 4"
        case .ch5: "CH 5"
        case .ch6: "CH 6"
        case .ch7: "CH 7"
        case .ch8: "CH 8"
        case .ch9: "CH 9"
        case .ch10: "CH 10"
        case .ch11: "CH 11"
        case .ch12: "CH 12"
        case .ch13: "CH 13"
        case .ch14: "CH 14"
        case .ch15: "CH 15"
        case .ch16: "CH 16"
        case .mainLr:
            "Main LR"
        }
    }

    var midiChannelCode: UInt8 {
        switch self {
        case .ch1: 0x20
        case .ch2: 0x21
        case .ch3: 0x22
        case .ch4: 0x23
        case .ch5: 0x24
        case .ch6: 0x25
        case .ch7: 0x26
        case .ch8: 0x27
        case .ch9: 0x28
        case .ch10: 0x29
        case .ch11: 0x2A
        case .ch12: 0x2B
        case .ch13: 0x2C
        case .ch14: 0x2D
        case .ch15: 0x2E
        case .ch16: 0x2F
        case .mainLr: 0x67
        }
    }

    init?(midiChannelCode: UInt8) {
        switch midiChannelCode {
        case 0x20: self = .ch1
        case 0x21: self = .ch2
        case 0x22: self = .ch3
        case 0x23: self = .ch4
        case 0x24: self = .ch5
        case 0x25: self = .ch6
        case 0x26: self = .ch7
        case 0x27: self = .ch8
        case 0x28: self = .ch9
        case 0x29: self = .ch10
        case 0x2A: self = .ch11
        case 0x2B: self = .ch12
        case 0x2C: self = .ch13
        case 0x2D: self = .ch14
        case 0x2E: self = .ch15
        case 0x2F: self = .ch16
        case 0x67: self = .mainLr
        default: return nil
        }
    }
}

struct MixerChannelState: Equatable, Identifiable {
    let id: MixerChannelID
    var level: FaderLevel
    var isMuted: Bool
    var hasSignal: Bool
    var customName: String?

    var displayName: String {
        guard let customName, !customName.isEmpty else {
            return id.defaultDisplayName
        }

        return customName
    }
}

enum MixerLayoutSurface: String, Codable {
    case mainScreen
}

struct MixerLayoutPreferences: Equatable, Codable {
    var mainScreenVisibleChannelIDs: [MixerChannelID]
    var mainScreenOrderedChannelIDs: [MixerChannelID]

    static let `default` = MixerLayoutPreferences(
        mainScreenVisibleChannelIDs: [.ch1, .ch2, .ch3, .ch4, .mainLr],
        mainScreenOrderedChannelIDs: MixerChannelID.selectableChannels
    )

    func channelIDs(for surface: MixerLayoutSurface) -> [MixerChannelID] {
        switch surface {
        case .mainScreen:
            let visibleIDs = visibleChannelIDs(for: surface)
            return orderedChannelIDs(for: surface).filter { visibleIDs.contains($0) }
        }
    }

    func orderedChannelIDs(for surface: MixerLayoutSurface) -> [MixerChannelID] {
        switch surface {
        case .mainScreen:
            sanitizedOrdered(mainScreenOrderedChannelIDs, fallback: Self.default.mainScreenOrderedChannelIDs)
        }
    }

    func visibleChannelIDs(for surface: MixerLayoutSurface) -> [MixerChannelID] {
        switch surface {
        case .mainScreen:
            sanitizedVisible(mainScreenVisibleChannelIDs, fallback: Self.default.mainScreenVisibleChannelIDs)
        }
    }

    mutating func setChannelVisibility(
        _ isVisible: Bool,
        for channelID: MixerChannelID,
        surface: MixerLayoutSurface
    ) {
        let currentIDs = visibleChannelIDs(for: surface)
        let updatedIDs = if isVisible {
            Self.append(channelID, to: currentIDs)
        } else {
            currentIDs.filter { $0 != channelID }
        }

        switch surface {
        case .mainScreen:
            mainScreenVisibleChannelIDs = updatedIDs
        }
    }

    mutating func moveChannelIDs(
        fromOffsets source: IndexSet,
        toOffset destination: Int,
        on surface: MixerLayoutSurface
    ) {
        var updatedIDs = orderedChannelIDs(for: surface)
        Self.move(&updatedIDs, fromOffsets: source, toOffset: destination)
        updatedIDs = Self.pinMainLR(updatedIDs)

        switch surface {
        case .mainScreen:
            mainScreenOrderedChannelIDs = updatedIDs
        }
    }

    mutating func resetChannelOrder(on surface: MixerLayoutSurface) {
        switch surface {
        case .mainScreen:
            mainScreenOrderedChannelIDs = Self.default.mainScreenOrderedChannelIDs
        }
    }

    private static func append(_ channelID: MixerChannelID, to channelIDs: [MixerChannelID]) -> [MixerChannelID] {
        let combined = channelIDs + [channelID]
        return selectable(channelIDs: combined)
    }

    private func sanitizedOrdered(_ channelIDs: [MixerChannelID], fallback: [MixerChannelID]) -> [MixerChannelID] {
        let sanitizedIDs = Self.sanitizedOrderedSelection(channelIDs, fallback: fallback)
        return sanitizedIDs.isEmpty ? fallback : sanitizedIDs
    }

    private func sanitizedVisible(_ channelIDs: [MixerChannelID], fallback: [MixerChannelID]) -> [MixerChannelID] {
        let sanitizedIDs = Self.sanitizedVisibleSelection(channelIDs)
        return sanitizedIDs.isEmpty ? fallback : sanitizedIDs
    }

    private static func selectable(channelIDs: [MixerChannelID]) -> [MixerChannelID] {
        MixerChannelID.selectableChannels.filter { channelIDs.contains($0) }
    }

    private static func sanitizedOrderedSelection(_ channelIDs: [MixerChannelID], fallback: [MixerChannelID]) -> [MixerChannelID] {
        var seen = Set<MixerChannelID>()
        let preservedOrder = channelIDs.filter { channelID in
            MixerChannelID.selectableChannels.contains(channelID) && seen.insert(channelID).inserted
        }

        if preservedOrder.isEmpty {
            return fallback
        }

        let missingChannelIDs = MixerChannelID.selectableChannels.filter { !seen.contains($0) }
        return pinMainLR(preservedOrder + missingChannelIDs)
    }

    private static func sanitizedVisibleSelection(_ channelIDs: [MixerChannelID]) -> [MixerChannelID] {
        var seen = Set<MixerChannelID>()
        return channelIDs.filter { channelID in
            MixerChannelID.selectableChannels.contains(channelID) && seen.insert(channelID).inserted
        }
    }

    private static func move(_ channelIDs: inout [MixerChannelID], fromOffsets source: IndexSet, toOffset destination: Int) {
        let movingItems = source.map { channelIDs[$0] }

        for index in source.sorted(by: >) {
            channelIDs.remove(at: index)
        }

        let insertionIndex = min(destination, channelIDs.count)
        channelIDs.insert(contentsOf: movingItems, at: insertionIndex)
    }

    private static func pinMainLR(_ channelIDs: [MixerChannelID]) -> [MixerChannelID] {
        channelIDs.filter { $0 != .mainLr } + [.mainLr]
    }

    init(
        mainScreenVisibleChannelIDs: [MixerChannelID],
        mainScreenOrderedChannelIDs: [MixerChannelID]
    ) {
        self.mainScreenVisibleChannelIDs = mainScreenVisibleChannelIDs
        self.mainScreenOrderedChannelIDs = mainScreenOrderedChannelIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let visibleIDs = try container.decodeIfPresent([MixerChannelID].self, forKey: .mainScreenVisibleChannelIDs),
           let orderedIDs = try container.decodeIfPresent([MixerChannelID].self, forKey: .mainScreenOrderedChannelIDs) {
            self.init(
                mainScreenVisibleChannelIDs: visibleIDs,
                mainScreenOrderedChannelIDs: orderedIDs
            )
            return
        }

        let legacyVisibleIDs = try container.decodeIfPresent([MixerChannelID].self, forKey: .mainScreenChannelIDs)
            ?? Self.default.mainScreenVisibleChannelIDs
        self.init(
            mainScreenVisibleChannelIDs: legacyVisibleIDs,
            mainScreenOrderedChannelIDs: Self.default.mainScreenOrderedChannelIDs
        )
    }

    enum CodingKeys: String, CodingKey {
        case mainScreenVisibleChannelIDs
        case mainScreenOrderedChannelIDs
        case mainScreenChannelIDs
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mainScreenVisibleChannelIDs, forKey: .mainScreenVisibleChannelIDs)
        try container.encode(mainScreenOrderedChannelIDs, forKey: .mainScreenOrderedChannelIDs)
    }
}

struct MixerEndpoint: Equatable {
    var host: String
    var port: Int = 51_325
}

enum MixerTransportMode: String, CaseIterable, Equatable {
    case direct
    case relay

    var defaultEndpoint: MixerEndpoint {
        switch self {
        case .direct:
            MixerEndpoint(host: "192.168.4.120", port: 51_325)
        case .relay:
            MixerEndpoint(host: "192.168.4.120", port: 51_326)
        }
    }

    var title: String {
        switch self {
        case .direct:
            "Direct Mixer"
        case .relay:
            "Mac Relay"
        }
    }
}

enum MixerConnectionPhase: Equatable {
    case disconnected
    case connecting
    case connected
    case error
}

struct MixerConnectionState: Equatable {
    var phase: MixerConnectionPhase
    var message: String
    var endpoint: MixerEndpoint?
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
