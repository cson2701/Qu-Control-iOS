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
            sanitized(mainScreenOrderedChannelIDs, fallback: Self.default.mainScreenOrderedChannelIDs)
        }
    }

    func visibleChannelIDs(for surface: MixerLayoutSurface) -> [MixerChannelID] {
        switch surface {
        case .mainScreen:
            sanitized(mainScreenVisibleChannelIDs, fallback: Self.default.mainScreenVisibleChannelIDs)
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

    private func sanitized(_ channelIDs: [MixerChannelID], fallback: [MixerChannelID]) -> [MixerChannelID] {
        let sanitizedIDs = Self.sanitizedSelection(channelIDs, fallback: fallback)
        return sanitizedIDs.isEmpty ? fallback : sanitizedIDs
    }

    private static func selectable(channelIDs: [MixerChannelID]) -> [MixerChannelID] {
        MixerChannelID.selectableChannels.filter { channelIDs.contains($0) }
    }

    private static func sanitizedSelection(_ channelIDs: [MixerChannelID], fallback: [MixerChannelID]) -> [MixerChannelID] {
        var seen = Set<MixerChannelID>()
        let preservedOrder = channelIDs.filter { channelID in
            MixerChannelID.selectableChannels.contains(channelID) && seen.insert(channelID).inserted
        }

        if preservedOrder.isEmpty {
            return fallback
        }

        let missingChannelIDs = MixerChannelID.selectableChannels.filter { !seen.contains($0) }
        return preservedOrder + missingChannelIDs
    }

    private static func move(_ channelIDs: inout [MixerChannelID], fromOffsets source: IndexSet, toOffset destination: Int) {
        let movingItems = source.map { channelIDs[$0] }

        for index in source.sorted(by: >) {
            channelIDs.remove(at: index)
        }

        let insertionIndex = min(destination, channelIDs.count)
        channelIDs.insert(contentsOf: movingItems, at: insertionIndex)
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
