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
}
