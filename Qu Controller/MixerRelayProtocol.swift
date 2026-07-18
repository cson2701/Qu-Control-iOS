import Foundation

struct MixerRelayClientCommand: Encodable {
    let type: String
    let channel: MixerChannelID?
    let level: Double?
    let isMuted: Bool?
    let isEnabled: Bool?

    static func setLevel(channel: MixerChannelID, level: Double) -> MixerRelayClientCommand {
        MixerRelayClientCommand(
            type: "setLevel",
            channel: channel,
            level: level,
            isMuted: nil,
            isEnabled: nil
        )
    }

    static func setMute(channel: MixerChannelID, isMuted: Bool) -> MixerRelayClientCommand {
        MixerRelayClientCommand(
            type: "setMute",
            channel: channel,
            level: nil,
            isMuted: isMuted,
            isEnabled: nil
        )
    }

    static func shutdown() -> MixerRelayClientCommand {
        MixerRelayClientCommand(
            type: "shutdown",
            channel: nil,
            level: nil,
            isMuted: nil,
            isEnabled: nil
        )
    }

    static func setSignalMonitoring(isEnabled: Bool) -> MixerRelayClientCommand {
        MixerRelayClientCommand(
            type: "setSignalMonitoring",
            channel: nil,
            level: nil,
            isMuted: nil,
            isEnabled: isEnabled
        )
    }
}

struct MixerRelayServerMessage: Decodable {
    let type: String
    let connection: MixerRelayConnectionSnapshot?
    let channels: [MixerRelayChannelSnapshot]?
    let message: String?
}

struct MixerRelayConnectionSnapshot: Decodable {
    let phase: String
    let message: String
    let endpoint: MixerRelayEndpointSnapshot?
}

struct MixerRelayEndpointSnapshot: Decodable {
    let host: String
    let port: Int
}

struct MixerRelayChannelSnapshot: Decodable {
    let id: MixerChannelID
    let level: Double
    let isMuted: Bool
    let hasSignal: Bool
    let name: String

    var channelState: MixerChannelState {
        MixerChannelState(
            id: id,
            level: FaderLevel(normalized: level),
            isMuted: isMuted,
            hasSignal: hasSignal,
            customName: name == id.defaultDisplayName ? nil : name
        )
    }
}
