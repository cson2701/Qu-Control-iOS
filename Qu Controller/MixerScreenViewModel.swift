//
//  MixerScreenViewModel.swift
//  Qu Controller
//

import Combine
import Foundation

@MainActor
final class MixerScreenViewModel: ObservableObject {
    enum DiscoveryState: Equatable {
        case idle
        case scanning
        case found(String)
        case unavailable
    }

    @Published var host: String
    @Published private(set) var channels: [MixerChannelState]
    @Published private(set) var connectionState: MixerConnectionState
    @Published private(set) var layoutPreferences: MixerLayoutPreferences
    @Published private(set) var discoveryState: DiscoveryState = .idle
    @Published private(set) var confirmBeforeShutdown: Bool
    @Published private(set) var autoConnectAfterDiscovery: Bool
    @Published private(set) var autoScanOnLaunch: Bool
    @Published private(set) var autoConnectLastKnownHostOnLaunch: Bool
    @Published private(set) var showSignalIndicators: Bool

    private let controller: MixerController
    private let defaultHost: String
    private let userDefaults: UserDefaults
    private var cancellables = Set<AnyCancellable>()
    private var discoveryTask: Task<Void, Never>?
    private var launchAutoConnectHost: String?

    init(
        controller: MixerController,
        defaultEndpoint: MixerEndpoint = MixerEndpoint(host: "192.168.4.120"),
        userDefaults: UserDefaults = .standard,
        startInitialConnectionFlow: Bool = true
    ) {
        self.controller = controller
        self.defaultHost = defaultEndpoint.host
        self.userDefaults = userDefaults
        host = Self.loadLastSuccessfulHost(from: userDefaults) ?? defaultEndpoint.host
        channels = controller.channels
        connectionState = controller.connectionState
        layoutPreferences = Self.loadLayoutPreferences(from: userDefaults)
        confirmBeforeShutdown = Self.loadConfirmBeforeShutdown(from: userDefaults)
        autoConnectAfterDiscovery = Self.loadAutoConnectAfterDiscovery(from: userDefaults)
        autoScanOnLaunch = Self.loadAutoScanOnLaunch(from: userDefaults)
        autoConnectLastKnownHostOnLaunch = Self.loadAutoConnectLastKnownHostOnLaunch(from: userDefaults)
        showSignalIndicators = Self.loadShowSignalIndicators(from: userDefaults)

        controller.channelsPublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$channels)

        controller.connectionStatePublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$connectionState)

        controller.connectionStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.handleConnectionStateChange(state)
            }
            .store(in: &cancellables)

        controller.connectionStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.updateSignalMonitoringState(for: state)
            }
            .store(in: &cancellables)

        updateSignalMonitoringState(for: connectionState)

        if startInitialConnectionFlow {
            startInitialConnectionFlowIfNeeded()
        }
    }

    var visibleMainScreenChannels: [MixerChannelState] {
        visibleChannels(for: .mainScreen)
    }

    var hostPublisher: AnyPublisher<String, Never> {
        $host.eraseToAnyPublisher()
    }

    var discoveryStatePublisher: AnyPublisher<DiscoveryState, Never> {
        $discoveryState.eraseToAnyPublisher()
    }

    var connectionStatePublisher: AnyPublisher<MixerConnectionState, Never> {
        $connectionState.eraseToAnyPublisher()
    }

    var layoutPreferencesPublisher: AnyPublisher<MixerLayoutPreferences, Never> {
        $layoutPreferences.eraseToAnyPublisher()
    }

    var confirmBeforeShutdownPublisher: AnyPublisher<Bool, Never> {
        $confirmBeforeShutdown.eraseToAnyPublisher()
    }

    var showSignalIndicatorsPublisher: AnyPublisher<Bool, Never> {
        $showSignalIndicators.eraseToAnyPublisher()
    }

    var supportsAutoDiscovery: Bool {
        controller is QuNetworkMixerController
    }

    var usesMockConnection: Bool {
        controller is MockMixerController
    }

    var rememberedHost: String? {
        Self.loadLastSuccessfulHost(from: userDefaults)
    }

    var hostPlaceholder: String {
        rememberedHost ?? defaultHost
    }

    var selectableChannels: [MixerChannelState] {
        let orderedIDs = layoutPreferences.orderedChannelIDs(for: .mainScreen)
        let channelsByID = Dictionary(uniqueKeysWithValues: displayChannels.map { ($0.id, $0) })

        return orderedIDs.compactMap { channelsByID[$0] }
    }

    private var displayChannels: [MixerChannelState] {
        guard connectionState.phase == .connected else {
            return channels.map { channel in
                MixerChannelState(
                    id: channel.id,
                    level: FaderLevel(normalized: 0),
                    isMuted: false,
                    hasSignal: false,
                    customName: channel.customName
                )
            }
        }

        return channels
    }

    var buttonTitle: String {
        switch connectionState.phase {
        case .connected, .connecting:
            "Disconnect"
        case .disconnected, .error:
            "Connect"
        }
    }

    var isFaderInteractive: Bool {
        connectionState.phase == .connected
    }

    var isShutdownAvailable: Bool {
        connectionState.phase == .connected
    }

    var statusMessage: String {
        if usesMockConnection, connectionState.phase == .disconnected {
            return "Demo Mode is enabled. Connect to use the simulated mixer."
        }

        return switch discoveryState {
        case .scanning where connectionState.phase == .disconnected:
            "Scanning local network for a Qu mixer..."
        case .found(let discoveredHost) where connectionState.phase == .disconnected:
            "Discovered mixer at \(discoveredHost)"
        case .unavailable where connectionState.phase == .disconnected:
            "No mixer discovered automatically. Enter an IP and connect manually."
        default:
            connectionState.message
        }
    }

    var isScanningForMixer: Bool {
        discoveryState == .scanning && connectionState.phase == .disconnected
    }

    var isAutoScanAvailable: Bool {
        controller is QuNetworkMixerController
            && isRetryableDiscoveryState
            && !isScanningForMixer
    }

    var scanButtonTitle: String {
        isScanningForMixer ? "Stop Scan" : "Find Mixer"
    }

    func toggleConnection() {
        switch connectionState.phase {
        case .connected, .connecting:
            controller.disconnect()
        case .disconnected, .error:
            let connectionHost = host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? rememberedHost ?? host
                : host
            Task {
                await controller.connect(to: MixerEndpoint(host: connectionHost))
            }
        }
    }

    func updateHost(_ host: String) {
        self.host = host
    }

    func setLevel(_ level: FaderLevel, for channelID: MixerChannelID) {
        controller.setLevel(for: channelID, level: level)
    }

    func setMute(_ isMuted: Bool, for channelID: MixerChannelID) {
        controller.setMute(for: channelID, isMuted: isMuted)
    }

    func toggleMainLRMute() {
        guard let mainLRChannel = channels.first(where: { $0.id == .mainLr }),
              connectionState.phase == .connected else {
            return
        }

        controller.setMute(for: .mainLr, isMuted: !mainLRChannel.isMuted)
    }

    func isChannelVisible(_ channelID: MixerChannelID, on surface: MixerLayoutSurface) -> Bool {
        layoutPreferences.channelIDs(for: surface).contains(channelID)
    }

    func setChannelVisibility(_ isVisible: Bool, for channelID: MixerChannelID, on surface: MixerLayoutSurface) {
        layoutPreferences.setChannelVisibility(isVisible, for: channelID, surface: surface)
        persistLayoutPreferences()
        objectWillChange.send()
    }

    func moveSelectableChannels(fromOffsets source: IndexSet, toOffset destination: Int, on surface: MixerLayoutSurface) {
        layoutPreferences.moveChannelIDs(fromOffsets: source, toOffset: destination, on: surface)
        persistLayoutPreferences()
        objectWillChange.send()
    }

    func resetChannelOrder(on surface: MixerLayoutSurface) {
        layoutPreferences.resetChannelOrder(on: surface)
        persistLayoutPreferences()
        objectWillChange.send()
    }

    func shutdownMixer() {
        Task {
            await controller.shutdownMixer()
        }
    }

    func setConfirmBeforeShutdown(_ isEnabled: Bool) {
        confirmBeforeShutdown = isEnabled
        userDefaults.set(isEnabled, forKey: AppSettingsKey.confirmBeforeShutdown)
    }

    func setAutoConnectAfterDiscovery(_ isEnabled: Bool) {
        autoConnectAfterDiscovery = isEnabled
        userDefaults.set(isEnabled, forKey: AppSettingsKey.autoConnectAfterDiscovery)
    }

    func setAutoScanOnLaunch(_ isEnabled: Bool) {
        autoScanOnLaunch = isEnabled
        userDefaults.set(isEnabled, forKey: AppSettingsKey.autoScanOnLaunch)
    }

    func setAutoConnectLastKnownHostOnLaunch(_ isEnabled: Bool) {
        autoConnectLastKnownHostOnLaunch = isEnabled
        userDefaults.set(isEnabled, forKey: AppSettingsKey.autoConnectLastKnownHostOnLaunch)
    }

    func setShowSignalIndicators(_ isEnabled: Bool) {
        showSignalIndicators = isEnabled
        userDefaults.set(isEnabled, forKey: AppSettingsKey.showSignalIndicators)
        updateSignalMonitoringState(for: connectionState)
    }

    func scanForMixer() {
        guard controller is QuNetworkMixerController, !isScanningForMixer else {
            return
        }

        startDiscovery()
    }

    func stopScanningForMixer() {
        guard isScanningForMixer else {
            return
        }

        discoveryTask?.cancel()
        discoveryTask = nil
        discoveryState = .idle
    }

    private func visibleChannels(for surface: MixerLayoutSurface) -> [MixerChannelState] {
        let visibleIDs = layoutPreferences.channelIDs(for: surface)
        return displayChannels.filter { visibleIDs.contains($0.id) }
            .sorted { lhs, rhs in
                visibleIDs.firstIndex(of: lhs.id) ?? 0 < visibleIDs.firstIndex(of: rhs.id) ?? 0
            }
    }

    private func persistLayoutPreferences() {
        guard let data = try? JSONEncoder().encode(layoutPreferences) else {
            return
        }

        userDefaults.set(data, forKey: AppSettingsKey.layoutPreferences)
    }

    private static func loadLayoutPreferences(from userDefaults: UserDefaults) -> MixerLayoutPreferences {
        guard let data = userDefaults.data(forKey: AppSettingsKey.layoutPreferences),
              let preferences = try? JSONDecoder().decode(MixerLayoutPreferences.self, from: data) else {
            return .default
        }

        return preferences
    }

    private static func loadLastSuccessfulHost(from userDefaults: UserDefaults) -> String? {
        guard let host = userDefaults.string(forKey: AppSettingsKey.lastSuccessfulHost),
              !host.isEmpty else {
            return nil
        }

        return host
    }

    private static func loadConfirmBeforeShutdown(from userDefaults: UserDefaults) -> Bool {
        guard userDefaults.object(forKey: AppSettingsKey.confirmBeforeShutdown) != nil else {
            return true
        }

        return userDefaults.bool(forKey: AppSettingsKey.confirmBeforeShutdown)
    }

    private static func loadAutoConnectAfterDiscovery(from userDefaults: UserDefaults) -> Bool {
        guard userDefaults.object(forKey: AppSettingsKey.autoConnectAfterDiscovery) != nil else {
            return false
        }

        return userDefaults.bool(forKey: AppSettingsKey.autoConnectAfterDiscovery)
    }

    private static func loadAutoScanOnLaunch(from userDefaults: UserDefaults) -> Bool {
        guard userDefaults.object(forKey: AppSettingsKey.autoScanOnLaunch) != nil else {
            return true
        }

        return userDefaults.bool(forKey: AppSettingsKey.autoScanOnLaunch)
    }

    private static func loadAutoConnectLastKnownHostOnLaunch(from userDefaults: UserDefaults) -> Bool {
        guard userDefaults.object(forKey: AppSettingsKey.autoConnectLastKnownHostOnLaunch) != nil else {
            return false
        }

        return userDefaults.bool(forKey: AppSettingsKey.autoConnectLastKnownHostOnLaunch)
    }

    private static func loadShowSignalIndicators(from userDefaults: UserDefaults) -> Bool {
        guard userDefaults.object(forKey: AppSettingsKey.showSignalIndicators) != nil else {
            return true
        }

        return userDefaults.bool(forKey: AppSettingsKey.showSignalIndicators)
    }

    private func updateSignalMonitoringState(for state: MixerConnectionState) {
        controller.setSignalMonitoringEnabled(showSignalIndicators && state.phase == .connected)
    }

    private var isRetryableDiscoveryState: Bool {
        switch connectionState.phase {
        case .disconnected, .error:
            true
        case .connected, .connecting:
            false
        }
    }

    private func startInitialConnectionFlowIfNeeded() {
        guard controller is QuNetworkMixerController else {
            return
        }

        guard autoScanOnLaunch || autoConnectLastKnownHostOnLaunch else {
            return
        }

        guard autoConnectLastKnownHostOnLaunch,
              let lastSuccessfulHost = Self.loadLastSuccessfulHost(from: userDefaults) else {
            if autoScanOnLaunch {
                startDiscovery()
            }
            return
        }

        launchAutoConnectHost = lastSuccessfulHost
        host = lastSuccessfulHost

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            let discovery = QuMixerDiscovery()
            if await discovery.isMixerReachable(at: lastSuccessfulHost) {
                await self.controller.connect(to: MixerEndpoint(host: lastSuccessfulHost))
            } else {
                self.launchAutoConnectHost = nil
                if self.autoScanOnLaunch {
                    self.startDiscovery()
                }
            }
        }
    }

    private func startDiscoveryFallbackIfNeeded(for state: MixerConnectionState) {
        guard autoScanOnLaunch else {
            return
        }

        guard let launchAutoConnectHost,
              state.phase == .error,
              state.endpoint?.host == launchAutoConnectHost else {
            return
        }

        self.launchAutoConnectHost = nil
        startDiscovery()
    }

    private func startDiscovery() {
        discoveryTask?.cancel()
        discoveryState = .scanning

        discoveryTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            let discovery = QuMixerDiscovery()
            let preferredHost = Self.loadLastSuccessfulHost(from: self.userDefaults)
            if let discoveredHost = await discovery.discoverMixer(preferredHost: preferredHost) {
                self.host = discoveredHost
                if self.autoConnectAfterDiscovery {
                    self.discoveryState = .idle
                    await self.controller.connect(to: MixerEndpoint(host: discoveredHost))
                } else {
                    self.discoveryState = .found(discoveredHost)
                }
            } else {
                self.discoveryState = .unavailable
            }
        }
    }

    private func handleConnectionStateChange(_ state: MixerConnectionState) {
        startDiscoveryFallbackIfNeeded(for: state)

        guard state.phase == .connected else {
            return
        }

        launchAutoConnectHost = nil
        discoveryTask?.cancel()
        discoveryTask = nil
        discoveryState = .idle

        guard let successfulHost = state.endpoint?.host,
              !successfulHost.isEmpty else {
            return
        }

        if host != successfulHost {
            host = successfulHost
        }

        userDefaults.set(successfulHost, forKey: AppSettingsKey.lastSuccessfulHost)
    }
}
