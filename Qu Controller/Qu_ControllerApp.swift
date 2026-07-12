//
//  Qu_ControllerApp.swift
//  Qu Controller
//
//  Created by Chaoran Song on 12/7/2026.
//

import SwiftUI

@main
struct Qu_ControllerApp: App {
    @State private var controllerMode: MixerControllerFactory.ControllerMode
    @State private var viewModel: MixerScreenViewModel

    init() {
        let initialControllerMode = MixerControllerFactory.currentControllerMode()
        _controllerMode = State(initialValue: initialControllerMode)
        _viewModel = State(
            initialValue: MixerScreenViewModel(
                controller: MixerControllerFactory.makeMixerController(mode: initialControllerMode)
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                viewModel: viewModel,
                isUsingMockConnection: controllerMode.usesMockConnection,
                onSetUseMockConnection: updateMockConnectionUsage(_:)
            )
        }
    }

    @MainActor
    private func updateMockConnectionUsage(_ usesMockConnection: Bool) {
        let nextMode: MixerControllerFactory.ControllerMode = usesMockConnection ? .mock : .network
        guard nextMode != controllerMode else {
            return
        }

        if usesMockConnection {
            viewModel.stopScanningForMixer()
        }

        controllerMode = nextMode
        MixerControllerFactory.setDebugControllerMode(nextMode)
        viewModel = MixerScreenViewModel(
            controller: MixerControllerFactory.makeMixerController(mode: nextMode)
        )
    }
}
