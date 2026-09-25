//
//  Qu_ControllerApp.swift
//  Qu Controller
//
//  Created by Chaoran Song on 12/7/2026.
//

import SwiftUI
import UIKit

@main
struct Qu_ControllerApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var transportMode: MixerTransportMode
    @State private var isUsingMockConnection: Bool
    @State private var viewModel: MixerScreenViewModel
    @State private var backgroundConnectionKeeper = BackgroundConnectionKeeper()

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
                onApplyConnectionMode: applyConnectionMode(_:)
            )
            .id("\(transportMode.rawValue)-\(isUsingMockConnection)")
            .onChange(of: scenePhase) { _, newPhase in
                handleScenePhaseChange(newPhase)
            }
        }
    }

    @MainActor
    private func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .background:
            if viewModel.applicationDidEnterBackground() {
                backgroundConnectionKeeper.begin()
            }
        case .active:
            backgroundConnectionKeeper.end()
            viewModel.applicationDidBecomeActive()
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    @MainActor
    private func applyConnectionMode(_ mode: ConnectionModeOption) {
        let nextState = resolvedState(for: mode)
        guard nextState.transportMode != transportMode || nextState.isUsingMockConnection != isUsingMockConnection else {
            return
        }

        transportMode = nextState.transportMode
        isUsingMockConnection = nextState.isUsingMockConnection
        let nextMode = controllerMode(
            for: nextState.transportMode,
            usesMockConnection: nextState.isUsingMockConnection
        )
        MixerControllerFactory.setTransportMode(nextState.transportMode)
        MixerControllerFactory.setDebugControllerMode(nextMode)
        rebuildViewModel(startInitialConnectionFlow: !nextState.isUsingMockConnection)
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

    private func resolvedState(for mode: ConnectionModeOption) -> (transportMode: MixerTransportMode, isUsingMockConnection: Bool) {
        switch mode {
        case .mixer:
            (transportMode: .direct, isUsingMockConnection: false)
        case .relay:
            (transportMode: .relay, isUsingMockConnection: false)
        case .demo:
            (transportMode: transportMode, isUsingMockConnection: true)
        }
    }
}

/// Requests the finite amount of background execution time that iOS grants for
/// completing in-flight work. This keeps the mixer socket and active-sensing
/// loop alive during brief app switches; it is not an unlimited background mode.
@MainActor
private final class BackgroundConnectionKeeper {
    private var taskIdentifier: UIBackgroundTaskIdentifier = .invalid

    func begin() {
        guard taskIdentifier == .invalid else {
            return
        }

        taskIdentifier = UIApplication.shared.beginBackgroundTask(
            withName: "Keep mixer connection alive"
        ) { [weak self] in
            self?.end()
        }
    }

    func end() {
        guard taskIdentifier != .invalid else {
            return
        }

        UIApplication.shared.endBackgroundTask(taskIdentifier)
        taskIdentifier = .invalid
    }
}
