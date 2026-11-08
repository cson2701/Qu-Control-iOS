//
//  MixerController.swift
//  Qu Controller
//

import Combine
import Foundation

@MainActor
protocol MixerController: AnyObject {
    var channels: [MixerChannelState] { get }
    var connectionState: MixerConnectionState { get }
    var faderWaveState: FaderWaveState { get }
    var channelsPublisher: AnyPublisher<[MixerChannelState], Never> { get }
    var connectionStatePublisher: AnyPublisher<MixerConnectionState, Never> { get }
    var faderWaveStatePublisher: AnyPublisher<FaderWaveState, Never> { get }

    func connect(to endpoint: MixerEndpoint) async
    func disconnect()
    func shutdownMixer() async throws
    func setLevel(for channelID: MixerChannelID, level: FaderLevel)
    func setMute(for channelID: MixerChannelID, isMuted: Bool)
    func setSignalMonitoringEnabled(_ isEnabled: Bool)
    func startFaderWave(configuration: FaderWaveConfiguration)
    func stopFaderWave()
}

enum MixerShutdownCommandError: LocalizedError {
    case notConnected
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            "Connect to a mixer before shutting it down."
        case let .commandFailed(message):
            "The mixer shutdown command failed. \(message)"
        }
    }
}
