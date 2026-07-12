//
//  MixerControllerFactory.swift
//  Qu Controller
//

import Foundation

enum MixerControllerFactory {
    enum ControllerMode: Equatable {
        case network
        case mock
    }

    private enum StorageKey {
        static let debugControllerMode = "mixer.debugControllerMode"
    }

    @MainActor
    static func makeMixerController(mode: ControllerMode) -> MixerController {
        switch mode {
        case .mock:
            return MockMixerController()
        case .network:
            return QuNetworkMixerController()
        }
    }

    static func currentControllerMode(userDefaults: UserDefaults = .standard) -> ControllerMode {
        if ProcessInfo.processInfo.environment["QU_CONTROLLER_USE_MOCK"] == "1" {
            return .mock
        }

#if DEBUG
        if userDefaults.string(forKey: StorageKey.debugControllerMode) == "mock" {
            return .mock
        }
#endif

        return .network
    }

    static func setDebugControllerMode(_ mode: ControllerMode, userDefaults: UserDefaults = .standard) {
#if DEBUG
        let storedValue = switch mode {
        case .network: "network"
        case .mock: "mock"
        }
        userDefaults.set(storedValue, forKey: StorageKey.debugControllerMode)
#endif
    }
}

extension MixerControllerFactory.ControllerMode {
    var usesMockConnection: Bool {
        self == .mock
    }
}
