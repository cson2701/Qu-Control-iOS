//
//  Qu_ControllerApp.swift
//  Qu Controller
//
//  Created by Chaoran Song on 12/7/2026.
//

import SwiftUI

@main
struct Qu_ControllerApp: App {
    @State private var transportMode: MixerTransportMode
    @State private var isUsingMockConnection: Bool
    @State private var viewModel: MixerScreenViewModel

    init() {
        let initialControllerMode = MixerControllerFactory.currentControllerMode()
        let initialTransportMode = initialControllerMode.transportMode
            ?? MixerControllerFactory.currentTransportMode()
        _transportMode = State(initialValue: initialTransportMode)
        _isUsingMockConnection = State(initialValue: initialControllerMode.usesMockConnection)
        _viewModel = State(
            initialValue: MixerScreenViewModel(
                controllerMode: initialControllerMode,
                transportMode: initialTransportMode,
                controller: MixerControllerFactory.makeMixerController(mode: initialControllerMode)
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                viewModel: viewModel,
                isUsingMockConnection: isUsingMockConnection,
                transportMode: transportMode,
                onSetUseMockConnection: updateMockConnectionUsage(_:),
                onSetTransportMode: updateTransportMode(_:)
            )
            .id("\(transportMode.rawValue)-\(isUsingMockConnection)")
        }
    }

    @MainActor
    private func updateMockConnectionUsage(_ usesMockConnection: Bool) {
        guard usesMockConnection != isUsingMockConnection else {
            return
        }

        isUsingMockConnection = usesMockConnection
        let nextMode = controllerMode(for: transportMode, usesMockConnection: usesMockConnection)
        MixerControllerFactory.setDebugControllerMode(nextMode)
        rebuildViewModel(startInitialConnectionFlow: !usesMockConnection)
    }

    @MainActor
    private func updateTransportMode(_ transportMode: MixerTransportMode) {
        guard transportMode != self.transportMode else {
            return
        }

        self.transportMode = transportMode
        MixerControllerFactory.setTransportMode(transportMode)
        rebuildViewModel(startInitialConnectionFlow: !isUsingMockConnection)
    }

    @MainActor
    private func rebuildViewModel(startInitialConnectionFlow: Bool) {
        viewModel.disconnectCurrentSession()
        let nextMode = controllerMode(for: transportMode, usesMockConnection: isUsingMockConnection)
        viewModel = MixerScreenViewModel(
            controllerMode: nextMode,
            transportMode: transportMode,
            controller: MixerControllerFactory.makeMixerController(mode: nextMode),
            startInitialConnectionFlow: startInitialConnectionFlow
        )
    }

    private func controllerMode(
        for transportMode: MixerTransportMode,
        usesMockConnection: Bool
    ) -> MixerControllerFactory.ControllerMode {
        if usesMockConnection {
            return .mock
        }

        return switch transportMode {
        case .direct:
            .direct
        case .relay:
            .relay
        }
    }
}
