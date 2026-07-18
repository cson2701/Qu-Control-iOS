//
//  MixerShutdownShortcutService.swift
//  Qu Controller
//

import Combine
import Foundation

@MainActor
final class MixerShutdownShortcutService {
    struct Result: Equatable {
        let host: String
    }

    private let userDefaults: UserDefaults
    private let controllerFactory: @MainActor () -> MixerController

    init(
        userDefaults: UserDefaults = .standard,
        controllerFactory: @escaping @MainActor () -> MixerController = {
            MixerControllerFactory.makeMixerController(mode: MixerControllerFactory.currentControllerMode())
        }
    ) {
        self.userDefaults = userDefaults
        self.controllerFactory = controllerFactory
    }

    func shutdownMixerUsingRememberedHost() async throws -> Result {
        let controller = controllerFactory()
        let transportMode = MixerControllerFactory.currentTransportMode(userDefaults: userDefaults)
        guard let rememberedEndpoint = rememberedEndpoint(for: transportMode) else {
            throw ShortcutShutdownError.noRememberedHost
        }

        return try await connectAndShutdown(at: rememberedEndpoint, using: controller)
    }

    private func connectAndShutdown(
        at endpoint: MixerEndpoint,
        using controller: MixerController
    ) async throws -> Result {
        if !isConnected(controller, to: endpoint) {
            await controller.connect(to: endpoint)
        }

        let connectedState = try await waitForConnectionOutcome(for: controller, endpoint: endpoint)
        guard connectedState.phase == .connected else {
            throw ShortcutShutdownError.connectionFailed(host: endpoint.host, message: connectedState.message)
        }

        remember(endpoint)

        await controller.shutdownMixer()
        let shutdownState = controller.connectionState

        if shutdownState.phase == .disconnected,
           shutdownState.message.contains("Shutdown command sent") {
            return Result(host: endpoint.host)
        }

        if shutdownState.phase == .error {
            throw ShortcutShutdownError.shutdownFailed(host: endpoint.host, message: shutdownState.message)
        }

        throw ShortcutShutdownError.shutdownFailed(host: endpoint.host, message: shutdownState.message)
    }

    private func waitForConnectionOutcome(
        for controller: MixerController,
        endpoint: MixerEndpoint
    ) async throws -> MixerConnectionState {
        if let immediateState = terminalConnectionState(from: controller.connectionState, endpoint: endpoint) {
            return immediateState
        }

        for await state in controller.connectionStatePublisher.values {
            if let terminalState = terminalConnectionState(from: state, endpoint: endpoint) {
                return terminalState
            }
        }

        throw ShortcutShutdownError.connectionFailed(
            host: endpoint.host,
            message: "Connection monitoring ended unexpectedly."
        )
    }

    private func terminalConnectionState(
        from state: MixerConnectionState,
        endpoint: MixerEndpoint
    ) -> MixerConnectionState? {
        guard state.endpoint?.host == endpoint.host else {
            return nil
        }

        switch state.phase {
        case .connected, .error:
            return state
        case .disconnected where state.message != "Disconnected":
            return state
        case .connecting, .disconnected:
            return nil
        }
    }

    private func isConnected(_ controller: MixerController, to endpoint: MixerEndpoint) -> Bool {
        let connectionState = controller.connectionState
        return connectionState.phase == .connected && connectionState.endpoint == endpoint
    }

    private func rememberedEndpoint(for transportMode: MixerTransportMode) -> MixerEndpoint? {
        switch transportMode {
        case .direct:
            guard let host = userDefaults.string(forKey: AppSettingsKey.lastSuccessfulHost),
                  !host.isEmpty else {
                return nil
            }

            return MixerEndpoint(host: host)
        case .relay:
            guard let host = userDefaults.string(forKey: AppSettingsKey.relayLastSuccessfulHost),
                  !host.isEmpty else {
                return nil
            }

            let storedPort = userDefaults.integer(forKey: AppSettingsKey.relayPort)
            let port = (1 ... 65_535).contains(storedPort)
                ? storedPort
                : MixerTransportMode.relay.defaultEndpoint.port
            return MixerEndpoint(host: host, port: port)
        }
    }

    private func remember(_ endpoint: MixerEndpoint) {
        let transportMode = MixerControllerFactory.currentTransportMode(userDefaults: userDefaults)
        switch transportMode {
        case .direct:
            userDefaults.set(endpoint.host, forKey: AppSettingsKey.lastSuccessfulHost)
        case .relay:
            userDefaults.set(endpoint.host, forKey: AppSettingsKey.relayLastSuccessfulHost)
            userDefaults.set(endpoint.port, forKey: AppSettingsKey.relayPort)
        }
    }
}

enum ShortcutShutdownError: LocalizedError {
    case noRememberedHost
    case connectionFailed(host: String, message: String)
    case shutdownFailed(host: String, message: String)

    var errorDescription: String? {
        switch self {
        case .noRememberedHost:
            "No previously connected mixer IP address is saved."
        case let .connectionFailed(host, message):
            "Could not connect to \(host). \(message)"
        case let .shutdownFailed(host, message):
            "Connected to \(host), but shutdown failed. \(message)"
        }
    }
}
