//
//  MockMixerController.swift
//  Qu Controller
//

import Combine
import Foundation

@MainActor
final class MockMixerController: MixerController {
    @Published private var storedChannels: [MixerChannelState] = MixerChannelID.selectableChannels.enumerated().map { index, channelID in
        let normalized = min(0.18 + (Double(index) * 0.04), 0.88)
        let customName: String? = switch channelID {
        case .ch1: "Kick"
        case .ch2: "Snare"
        case .ch3: "Bass"
        case .ch4: "Guitar"
        case .mainLr: "Main LR"
        default: nil
        }

        return MixerChannelState(
            id: channelID,
            level: FaderLevel(normalized: normalized),
            isMuted: false,
            hasSignal: channelID == .ch1 || channelID == .ch2 || channelID == .mainLr,
            customName: customName
        )
    }
    @Published private var storedConnectionState = MixerConnectionState(
        phase: .disconnected,
        message: "Demo mode disconnected",
        endpoint: nil
    )
    @Published private var storedFaderWaveState = FaderWaveState.disconnected
    private var faderWaveTask: Task<Void, Never>?

    var channels: [MixerChannelState] {
        storedChannels
    }

    var connectionState: MixerConnectionState {
        storedConnectionState
    }

    var faderWaveState: FaderWaveState {
        storedFaderWaveState
    }

    var channelsPublisher: AnyPublisher<[MixerChannelState], Never> {
        $storedChannels.eraseToAnyPublisher()
    }

    var connectionStatePublisher: AnyPublisher<MixerConnectionState, Never> {
        $storedConnectionState.eraseToAnyPublisher()
    }

    var faderWaveStatePublisher: AnyPublisher<FaderWaveState, Never> {
        $storedFaderWaveState.eraseToAnyPublisher()
    }

    func connect(to endpoint: MixerEndpoint) async {
        storedConnectionState = MixerConnectionState(
            phase: .connecting,
            message: "Connecting to \(endpoint.host):\(endpoint.port)",
            endpoint: endpoint
        )

        try? await Task.sleep(for: .milliseconds(250))

        storedConnectionState = MixerConnectionState(
            phase: .connected,
            message: "Demo mode connected",
            endpoint: endpoint
        )
        storedFaderWaveState = .ready
    }

    func disconnect() {
        faderWaveTask?.cancel()
        faderWaveTask = nil
        storedFaderWaveState = .disconnected
        storedConnectionState = MixerConnectionState(
            phase: .disconnected,
            message: "Demo mode disconnected",
            endpoint: nil
        )
    }

    func shutdownMixer() async {
        faderWaveTask?.cancel()
        faderWaveTask = nil
        storedFaderWaveState = .disconnected
        storedConnectionState = MixerConnectionState(
            phase: .disconnected,
            message: "Demo mode shutdown complete",
            endpoint: nil
        )
    }

    func setLevel(for channelID: MixerChannelID, level: FaderLevel) {
        storedChannels = storedChannels.map { channel in
            guard channel.id == channelID else {
                return channel
            }
            return MixerChannelState(
                id: channel.id,
                level: level,
                isMuted: channel.isMuted,
                hasSignal: channel.hasSignal,
                customName: channel.customName
            )
        }
    }

    func setMute(for channelID: MixerChannelID, isMuted: Bool) {
        storedChannels = storedChannels.map { channel in
            guard channel.id == channelID else {
                return channel
            }

            return MixerChannelState(
                id: channel.id,
                level: channel.level,
                isMuted: isMuted,
                hasSignal: channel.hasSignal,
                customName: channel.customName
            )
        }
    }

    func setSignalMonitoringEnabled(_ isEnabled: Bool) {
        guard !isEnabled else {
            return
        }

        storedChannels = storedChannels.map { channel in
            MixerChannelState(
                id: channel.id,
                level: channel.level,
                isMuted: channel.isMuted,
                hasSignal: false,
                customName: channel.customName
            )
        }
    }

    func startFaderWave(configuration: FaderWaveConfiguration) {
        guard storedConnectionState.phase == .connected, faderWaveTask == nil else { return }

        storedFaderWaveState = .running(progress: 0)
        let frameCount = FaderWaveAnimation.frameCount(for: configuration)
        faderWaveTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                for frame in 0 ... frameCount {
                    try Task.checkCancellation()
                    let progress = Double(frame) / Double(frameCount)
                    self.storedFaderWaveState = .running(progress: progress)
                    if frame < frameCount {
                        try await Task.sleep(for: FaderWaveAnimation.frameInterval)
                    }
                }
            } catch {
                // Cancellation follows the same restoration state as a mixer run.
            }

            guard self.storedConnectionState.phase == .connected else {
                self.faderWaveTask = nil
                return
            }

            self.storedFaderWaveState = .restoring
            try? await Task.sleep(for: .milliseconds(300))
            self.faderWaveTask = nil
            if self.storedConnectionState.phase == .connected {
                self.storedFaderWaveState = .ready
            }
        }
    }

    func stopFaderWave() {
        faderWaveTask?.cancel()
    }
}
