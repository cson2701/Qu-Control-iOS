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
            MixerControllerFactory.makeMixerController(mode: .network)
        }
    ) {
        self.userDefaults = userDefaults
        self.controllerFactory = controllerFactory
    }

    func shutdownMixerUsingRememberedHost() async throws -> Result {
        let controller = controllerFactory()
        guard let rememberedHost = lastSuccessfulHost() else {
            throw ShortcutShutdownError.noRememberedHost
        }

        return try await connectAndShutdown(at: rememberedHost, using: controller)
    }

    private func connectAndShutdown(
        at host: String,
        using controller: MixerController
    ) async throws -> Result {
        let endpoint = MixerEndpoint(host: host)
        await controller.connect(to: endpoint)

        let connectedState = try await waitForConnectionOutcome(for: controller, endpoint: endpoint)
        guard connectedState.phase == .connected else {
            throw ShortcutShutdownError.connectionFailed(host: host, message: connectedState.message)
        }

        userDefaults.set(host, forKey: AppSettingsKey.lastSuccessfulHost)

        await controller.shutdownMixer()
        let shutdownState = controller.connectionState

        if shutdownState.phase == .disconnected,
           shutdownState.message.contains("Shutdown command sent") {
            return Result(host: host)
        }

        if shutdownState.phase == .error {
            throw ShortcutShutdownError.shutdownFailed(host: host, message: shutdownState.message)
        }

        throw ShortcutShutdownError.shutdownFailed(host: host, message: shutdownState.message)
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

    private func lastSuccessfulHost() -> String? {
        guard let host = userDefaults.string(forKey: AppSettingsKey.lastSuccessfulHost),
              !host.isEmpty else {
            return nil
        }

        return host
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
