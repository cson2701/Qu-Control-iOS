import Foundation

struct MixerRelayClientCommand: Encodable {
    let type: String
    let channel: MixerChannelID?
    let level: Double?
    let isMuted: Bool?
    let isEnabled: Bool?
    let cycles: Double?
    let speed: Double?

    static func setLevel(channel: MixerChannelID, level: Double) -> MixerRelayClientCommand {
        MixerRelayClientCommand(
            type: "setLevel",
            channel: channel,
            level: level,
            isMuted: nil,
            isEnabled: nil,
            cycles: nil,
            speed: nil
        )
    }

    static func setMute(channel: MixerChannelID, isMuted: Bool) -> MixerRelayClientCommand {
        MixerRelayClientCommand(
            type: "setMute",
            channel: channel,
            level: nil,
            isMuted: isMuted,
            isEnabled: nil,
            cycles: nil,
            speed: nil
        )
    }

    static func shutdownMixer() -> MixerRelayClientCommand {
        MixerRelayClientCommand(
            type: "shutdownMixer",
            channel: nil,
            level: nil,
            isMuted: nil,
            isEnabled: nil,
            cycles: nil,
            speed: nil
        )
    }

    static func setSignalMonitoring(isEnabled: Bool) -> MixerRelayClientCommand {
        MixerRelayClientCommand(
            type: "setSignalMonitoring",
            channel: nil,
            level: nil,
            isMuted: nil,
            isEnabled: isEnabled,
            cycles: nil,
            speed: nil
        )
    }

    static func startFaderWave(configuration: FaderWaveConfiguration) -> MixerRelayClientCommand {
        MixerRelayClientCommand(
            type: "startFaderWave",
            channel: nil,
            level: nil,
            isMuted: nil,
            isEnabled: nil,
            cycles: configuration.cycles,
            speed: configuration.speed
        )
    }

    static func stopFaderWave() -> MixerRelayClientCommand {
        MixerRelayClientCommand(
            type: "stopFaderWave",
            channel: nil,
            level: nil,
            isMuted: nil,
            isEnabled: nil,
            cycles: nil,
            speed: nil
        )
    }
}

struct MixerRelayServerMessage: Decodable {
    let type: String
    let connection: MixerRelayConnectionSnapshot?
    let channels: [MixerRelayChannelSnapshot]?
    let faderWave: FaderWaveState?
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
