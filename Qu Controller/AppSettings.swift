import Foundation

enum AppSettingsKey {
    static let transportMode = "mixer.transportMode"
    static let layoutPreferences = "mixer.layoutPreferences"
    static let lastSuccessfulHost = "mixer.lastSuccessfulHost"
    static let relayLastSuccessfulHost = "relay.lastSuccessfulHost"
    static let relayPort = "relay.port"
    static let confirmBeforeShutdown = "settings.confirmBeforeShutdown"
    static let autoConnectAfterDiscovery = "settings.autoConnectAfterDiscovery"
    static let autoScanOnLaunch = "settings.autoScanOnLaunch"
    static let autoConnectLastKnownHostOnLaunch = "settings.autoConnectLastKnownHostOnLaunch"
    static let showSignalIndicators = "settings.showSignalIndicators"
    static let faderWaveCycles = "settings.faderWave.cycles"
    static let faderWaveSpeed = "settings.faderWave.speed"
}

enum AppSettings {
    static func loadFaderWaveConfiguration(
        from userDefaults: UserDefaults = .standard
    ) -> FaderWaveConfiguration {
        let cycles = userDefaults.object(forKey: AppSettingsKey.faderWaveCycles) == nil
            ? FaderWaveConfiguration.defaultCycles
            : userDefaults.double(forKey: AppSettingsKey.faderWaveCycles)
        let speed = userDefaults.object(forKey: AppSettingsKey.faderWaveSpeed) == nil
            ? FaderWaveConfiguration.defaultSpeed
            : userDefaults.double(forKey: AppSettingsKey.faderWaveSpeed)

        return FaderWaveConfiguration(cycles: cycles, speed: speed)
    }
}
