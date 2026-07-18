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
    @Published private(set) var relayPort: Int

    private let controllerMode: MixerControllerFactory.ControllerMode
    private let transportMode: MixerTransportMode
    private let controller: MixerController
    private let userDefaults: UserDefaults
    private var cancellables = Set<AnyCancellable>()
    private var discoveryTask: Task<Void, Never>?
    private var launchAutoConnectHost: String?

    init(
        controllerMode: MixerControllerFactory.ControllerMode,
        transportMode: MixerTransportMode,
        controller: MixerController,
        userDefaults: UserDefaults = .standard,
        startInitialConnectionFlow: Bool = true
    ) {
        self.controllerMode = controllerMode
        self.transportMode = transportMode
        self.controller = controller
        self.userDefaults = userDefaults
        let rememberedEndpoint = Self.loadRememberedEndpoint(
            from: userDefaults,
            transportMode: transportMode
        )
        host = rememberedEndpoint.host
        channels = controller.channels
        connectionState = controller.connectionState
        layoutPreferences = Self.loadLayoutPreferences(from: userDefaults)
        confirmBeforeShutdown = Self.loadConfirmBeforeShutdown(from: userDefaults)
        autoConnectAfterDiscovery = Self.loadAutoConnectAfterDiscovery(from: userDefaults)
        autoScanOnLaunch = Self.loadAutoScanOnLaunch(from: userDefaults)
        autoConnectLastKnownHostOnLaunch = Self.loadAutoConnectLastKnownHostOnLaunch(from: userDefaults)
        showSignalIndicators = Self.loadShowSignalIndicators(from: userDefaults)
        relayPort = Self.loadRelayPort(from: userDefaults)

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

    var selectedTransportMode: MixerTransportMode {
        transportMode
    }

    var supportsAutoDiscovery: Bool {
        transportMode == .direct && controllerMode != .mock
    }

    var usesMockConnection: Bool {
        controllerMode == .mock
    }

    var rememberedHost: String? {
        Self.loadRememberedEndpoint(from: userDefaults, transportMode: transportMode).host
    }

    var hostPlaceholder: String {
        rememberedHost ?? transportMode.defaultEndpoint.host
    }

    var currentPort: Int {
        switch transportMode {
        case .direct:
            transportMode.defaultEndpoint.port
        case .relay:
            relayPort
        }
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

        if transportMode == .relay {
            return connectionState.message
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
        transportMode == .direct && controllerMode != .mock
            && isRetryableDiscoveryState
            && !isScanningForMixer
    }

    var scanButtonTitle: String {
        isScanningForMixer ? "Stop Scan" : "Find Mixer"
    }

    func toggleConnection(relayPortOverride: Int? = nil) {
        switch connectionState.phase {
        case .connected, .connecting:
            controller.disconnect()
        case .disconnected, .error:
            let connectionHost = host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? rememberedHost ?? host
                : host
            let port: Int
            if transportMode == .relay, let relayPortOverride {
                port = relayPortOverride
            } else {
                port = currentPort
            }
            Task {
                await controller.connect(to: MixerEndpoint(host: connectionHost, port: port))
            }
        }
    }

    func disconnectCurrentSession() {
        stopScanningForMixer()
        controller.disconnect()
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

    func setRelayPort(_ port: Int) {
        guard (1 ... 65_535).contains(port) else {
            return
        }

        relayPort = port
        userDefaults.set(port, forKey: AppSettingsKey.relayPort)
    }

    func scanForMixer() {
        guard transportMode == .direct, controllerMode != .mock, !isScanningForMixer else {
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

    private static func loadRememberedEndpoint(
        from userDefaults: UserDefaults,
        transportMode: MixerTransportMode
    ) -> MixerEndpoint {
        switch transportMode {
        case .direct:
            let host = userDefaults.string(forKey: AppSettingsKey.lastSuccessfulHost)
            return MixerEndpoint(
                host: (host?.isEmpty == false ? host : nil) ?? transportMode.defaultEndpoint.host,
                port: transportMode.defaultEndpoint.port
            )
        case .relay:
            let host = userDefaults.string(forKey: AppSettingsKey.relayLastSuccessfulHost)
            let port = loadRelayPort(from: userDefaults)
            return MixerEndpoint(
                host: (host?.isEmpty == false ? host : nil) ?? transportMode.defaultEndpoint.host,
                port: port
            )
        }
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

    private static func loadRelayPort(from userDefaults: UserDefaults) -> Int {
        let storedPort = userDefaults.integer(forKey: AppSettingsKey.relayPort)
        return (1 ... 65_535).contains(storedPort) ? storedPort : MixerTransportMode.relay.defaultEndpoint.port
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
        guard controllerMode != .mock else {
            return
        }

        guard autoConnectLastKnownHostOnLaunch || (transportMode == .direct && autoScanOnLaunch) else {
            return
        }

        let rememberedEndpoint = Self.loadRememberedEndpoint(from: userDefaults, transportMode: transportMode)

        guard autoConnectLastKnownHostOnLaunch else {
            if transportMode == .direct && autoScanOnLaunch {
                startDiscovery()
            }
            return
        }

        launchAutoConnectHost = rememberedEndpoint.host
        host = rememberedEndpoint.host

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            if self.transportMode == .relay {
                await self.controller.connect(to: rememberedEndpoint)
            } else {
                let discovery = QuMixerDiscovery()
                if await discovery.isMixerReachable(at: rememberedEndpoint.host) {
                    await self.controller.connect(to: rememberedEndpoint)
                } else {
                    self.launchAutoConnectHost = nil
                    if self.autoScanOnLaunch {
                        self.startDiscovery()
                    }
                }
            }
        }
    }

    private func startDiscoveryFallbackIfNeeded(for state: MixerConnectionState) {
        guard transportMode == .direct else {
            return
        }

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
            let preferredHost = Self.loadRememberedEndpoint(
                from: self.userDefaults,
                transportMode: .direct
            ).host
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

        let successfulHost: String
        switch transportMode {
        case .direct:
            guard let endpointHost = state.endpoint?.host,
                  !endpointHost.isEmpty else {
                return
            }
            successfulHost = endpointHost
            if host != successfulHost {
                host = successfulHost
            }
            userDefaults.set(successfulHost, forKey: AppSettingsKey.lastSuccessfulHost)
        case .relay:
            let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
            successfulHost = trimmedHost.isEmpty ? hostPlaceholder : trimmedHost
            userDefaults.set(successfulHost, forKey: AppSettingsKey.relayLastSuccessfulHost)
        }
    }
}
