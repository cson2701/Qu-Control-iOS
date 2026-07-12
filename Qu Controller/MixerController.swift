//
//  MixerController.swift
//  Qu Controller
//

import Combine

@MainActor
protocol MixerController: AnyObject {
    var channels: [MixerChannelState] { get }
    var connectionState: MixerConnectionState { get }
    var channelsPublisher: AnyPublisher<[MixerChannelState], Never> { get }
    var connectionStatePublisher: AnyPublisher<MixerConnectionState, Never> { get }

    func connect(to endpoint: MixerEndpoint) async
    func disconnect()
    func shutdownMixer() async
    func setLevel(for channelID: MixerChannelID, level: FaderLevel)
    func setMute(for channelID: MixerChannelID, isMuted: Bool)
    func setSignalMonitoringEnabled(_ isEnabled: Bool)
}
