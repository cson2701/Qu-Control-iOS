//
//  MixerControllerFactory.swift
//  Qu Controller
//

import Foundation

enum MixerControllerFactory {
    enum ControllerMode: Equatable {
        case direct
        case relay
        case mock
    }

    private enum StorageKey {
        static let debugControllerMode = "mixer.debugControllerMode"
    }

    @MainActor
    private static let sharedDirectController = QuNetworkMixerController()
    @MainActor
    private static let sharedRelayController = QuRelayMixerController()

    @MainActor
    static func makeMixerController(mode: ControllerMode) -> MixerController {
        switch mode {
        case .direct:
            return sharedDirectController
        case .relay:
            return sharedRelayController
        case .mock:
            return MockMixerController()
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

        let transportMode = currentTransportMode(userDefaults: userDefaults)

        return switch transportMode {
        case .direct:
            .direct
        case .relay:
            .relay
        }
    }

    static func currentTransportMode(userDefaults: UserDefaults = .standard) -> MixerTransportMode {
        MixerTransportMode(
            rawValue: userDefaults.string(forKey: AppSettingsKey.transportMode) ?? ""
        ) ?? .direct
    }

    static func setDebugControllerMode(_ mode: ControllerMode, userDefaults: UserDefaults = .standard) {
#if DEBUG
        let storedValue = switch mode {
        case .direct: "direct"
        case .relay: "relay"
        case .mock: "mock"
        }
        userDefaults.set(storedValue, forKey: StorageKey.debugControllerMode)
#endif
    }

    static func setTransportMode(_ mode: MixerTransportMode, userDefaults: UserDefaults = .standard) {
        userDefaults.set(mode.rawValue, forKey: AppSettingsKey.transportMode)
    }
}

extension MixerControllerFactory.ControllerMode {
    var usesMockConnection: Bool {
        self == .mock
    }

    var transportMode: MixerTransportMode? {
        switch self {
        case .direct:
            .direct
        case .relay:
            .relay
        case .mock:
            nil
        }
    }
}
