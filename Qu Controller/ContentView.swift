//
//  ContentView.swift
//  Qu Controller
//
//  Created by Chaoran Song on 12/7/2026.
//

import Combine
import SwiftUI

struct ContentView: View {
    let viewModel: MixerScreenViewModel
    let isUsingMockConnection: Bool
    let onSetUseMockConnection: (Bool) -> Void

    @StateObject private var chromeModel: ContentChromeModel
    @State private var isShowingSettings = false
    @State private var isShowingShutdownConfirmation = false
    @State private var isShowingStatusDetails = false

    init(
        viewModel: MixerScreenViewModel,
        isUsingMockConnection: Bool,
        onSetUseMockConnection: @escaping (Bool) -> Void
    ) {
        self.viewModel = viewModel
        self.isUsingMockConnection = isUsingMockConnection
        self.onSetUseMockConnection = onSetUseMockConnection
        _chromeModel = StateObject(wrappedValue: ContentChromeModel(viewModel: viewModel))
    }

    var body: some View {
        NavigationStack {
            Group {
                if chromeModel.connectionState.phase == .connected {
                    ConnectedMixerContent(viewModel: viewModel)
                } else {
                    disconnectedContent
                }
            }
            .navigationTitle("Qu Controller")
            .toolbar {
                if chromeModel.connectionState.phase == .connected {
                    ToolbarItem(placement: .topBarTrailing) {
                        connectedStatusButton
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    if chromeModel.connectionState.phase == .connected {
                        connectedOverflowMenu
                    } else {
                        Button {
                            isShowingSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(
                viewModel: viewModel,
                isUsingMockConnection: isUsingMockConnection,
                onSetUseMockConnection: onSetUseMockConnection
            )
        }
        .confirmationDialog(
            "Shut Down Mixer",
            isPresented: $isShowingShutdownConfirmation,
            titleVisibility: .visible
        ) {
            Button("Shut Down Mixer", role: .destructive) {
                viewModel.shutdownMixer()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This powers off the connected Qu mixer and may require a hard power reset to turn it back on.")
        }
        .sheet(isPresented: $isShowingStatusDetails) {
            StatusDetailsSheet(
                title: chromeModel.statusSheetTitle,
                message: chromeModel.statusDetailsMessage,
                phase: chromeModel.connectionState.phase
            )
            .presentationDetents([.height(chromeModel.statusSheetHeight)])
            .presentationDragIndicator(.visible)
        }
    }

    private var connectedStatusButton: some View {
        Button {
            isShowingStatusDetails = true
        } label: {
            Image(systemName: statusIconName(for: chromeModel.connectionState.phase))
                .foregroundStyle(statusColor(for: chromeModel.connectionState.phase))
        }
    }

    private var connectedOverflowMenu: some View {
        Menu {
            Button {
                isShowingSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }

            Button {
                viewModel.toggleConnection()
            } label: {
                Label("Disconnect", systemImage: "cable.connector.slash")
            }

            Button(role: .destructive) {
                if viewModel.confirmBeforeShutdown {
                    isShowingShutdownConfirmation = true
                } else {
                    viewModel.shutdownMixer()
                }
            } label: {
                Label("Shut Down Mixer", systemImage: "power")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    private var disconnectedContent: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Connect to a Qu mixer")
                        .font(.title2.weight(.semibold))

                    Text("Enter the mixer IP address directly or scan the local network to find it.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Mixer IP")
                        .font(.headline)

                    TextField(chromeModel.hostPlaceholder, text: hostBinding)
                        .keyboardType(.decimalPad)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.go)
                        .onSubmit {
                            if (chromeModel.connectionState.phase == .disconnected || chromeModel.connectionState.phase == .error)
                                && chromeModel.canConnect {
                                viewModel.toggleConnection()
                            }
                        }

                    if let hostValidationMessage = chromeModel.hostValidationMessage {
                        Text(hostValidationMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Text("Port 51325")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ConnectionStatusCard(
                    title: "Status",
                    message: chromeModel.statusMessage,
                    phase: chromeModel.connectionState.phase,
                    isScanning: chromeModel.isScanningForMixer
                )

                VStack(spacing: 12) {
                    Button(chromeModel.buttonTitle) {
                        viewModel.toggleConnection()
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .disabled(chromeModel.isPrimaryActionDisabled)

                    Button(viewModel.scanButtonTitle) {
                        if chromeModel.isScanningForMixer {
                            viewModel.stopScanningForMixer()
                        } else {
                            viewModel.scanForMixer()
                        }
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                    .disabled(!chromeModel.isScanningForMixer && !chromeModel.isAutoScanAvailable)
                }
            }
            .frame(maxWidth: 560)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
    }

    private var hostBinding: Binding<String> {
        Binding(
            get: { chromeModel.host },
            set: { newValue in
                let sanitizedValue = ContentChromeModel.sanitizeIPv4Input(newValue)
                chromeModel.host = sanitizedValue
                viewModel.updateHost(sanitizedValue)
            }
        )
    }
}

@MainActor
private final class ContentChromeModel: ObservableObject {
    @Published var host: String
    @Published private(set) var connectionState: MixerConnectionState
    @Published private(set) var discoveryState: MixerScreenViewModel.DiscoveryState
    @Published private(set) var confirmBeforeShutdown: Bool
    @Published private(set) var visibleMainScreenChannelCount: Int
    @Published private(set) var rememberedHost: String?
    @Published private(set) var hostPlaceholder: String

    private let supportsAutoDiscovery: Bool
    private var cancellables = Set<AnyCancellable>()

    init(viewModel: MixerScreenViewModel) {
        host = viewModel.host
        connectionState = viewModel.connectionState
        discoveryState = viewModel.discoveryState
        confirmBeforeShutdown = viewModel.confirmBeforeShutdown
        visibleMainScreenChannelCount = viewModel.visibleMainScreenChannels.count
        rememberedHost = viewModel.rememberedHost
        hostPlaceholder = viewModel.hostPlaceholder
        supportsAutoDiscovery = viewModel.supportsAutoDiscovery

        viewModel.hostPublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$host)

        viewModel.connectionStatePublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$connectionState)

        viewModel.discoveryStatePublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$discoveryState)

        viewModel.confirmBeforeShutdownPublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$confirmBeforeShutdown)

        viewModel.layoutPreferencesPublisher
            .receive(on: DispatchQueue.main)
            .map { preferences in
                preferences.channelIDs(for: .mainScreen).count
            }
            .assign(to: &$visibleMainScreenChannelCount)
    }

    var buttonTitle: String {
        switch connectionState.phase {
        case .connected, .connecting:
            "Disconnect"
        case .disconnected, .error:
            "Connect"
        }
    }

    var effectiveHost: String {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedHost.isEmpty {
            return trimmedHost
        }

        return rememberedHost ?? ""
    }

    var isHostValid: Bool {
        Self.isValidIPv4Address(effectiveHost)
    }

    var canConnect: Bool {
        isHostValid
    }

    var hostValidationMessage: String? {
        guard !host.isEmpty, !isHostValid else {
            return nil
        }

        return "Enter a valid IPv4 address like \(hostPlaceholder)."
    }

    var statusMessage: String {
        switch discoveryState {
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

    var statusDetailsMessage: String {
        if connectionState.phase == .connected {
            return "\(visibleMainScreenChannelCount) visible channels\n\n\(connectionState.message)"
        }

        return statusMessage
    }

    var statusSheetTitle: String {
        if connectionState.phase == .connected {
            return "Mixer Connected"
        }

        return "Connection Status"
    }

    var statusSheetHeight: CGFloat {
        switch connectionState.phase {
        case .connected:
            return 210
        case .connecting:
            return 180
        case .disconnected, .error:
            return 170
        }
    }

    var isScanningForMixer: Bool {
        discoveryState == .scanning && connectionState.phase == .disconnected
    }

    var isAutoScanAvailable: Bool {
        supportsAutoDiscovery && isRetryableDiscoveryState && !isScanningForMixer
    }

    var isPrimaryActionDisabled: Bool {
        switch connectionState.phase {
        case .connected, .connecting:
            false
        case .disconnected, .error:
            !canConnect
        }
    }

    static func sanitizeIPv4Input(_ value: String) -> String {
        var sanitized = ""
        var octetLength = 0
        var dotCount = 0

        for character in value {
            if character.isWholeNumber {
                guard dotCount < 4, octetLength < 3 else {
                    continue
                }

                sanitized.append(character)
                octetLength += 1
                continue
            }

            guard character == ".", !sanitized.isEmpty, sanitized.last != ".", dotCount < 3 else {
                continue
            }

            sanitized.append(character)
            dotCount += 1
            octetLength = 0
        }

        return sanitized
    }

    static func isValidIPv4Address(_ value: String) -> Bool {
        let octets = value.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else {
            return false
        }

        for octet in octets {
            guard !octet.isEmpty,
                  octet.count <= 3,
                  let octetValue = Int(octet),
                  octetValue <= 255 else {
                return false
            }
        }

        return true
    }

    private var isRetryableDiscoveryState: Bool {
        switch connectionState.phase {
        case .disconnected, .error:
            true
        case .connected, .connecting:
            false
        }
    }
}

private struct ConnectedMixerContent: View {
    @ObservedObject var viewModel: MixerScreenViewModel

    var body: some View {
        GeometryReader { geometry in
            let usesWideMixerLayout = geometry.size.width > geometry.size.height || geometry.size.width >= 700
            let wideLayoutHeight = max(0, geometry.size.height - 40)
            let visibleChannels = viewModel.visibleMainScreenChannels
            let mainLRChannel = visibleChannels.first(where: { $0.id == .mainLr })
            let scrollableChannels = visibleChannels.filter { $0.id != .mainLr }

            Group {
                if usesWideMixerLayout {
                    VStack(alignment: .leading, spacing: 20) {
                        AdaptiveMixerSurface(
                            channels: visibleChannels,
                            showsSignalIndicators: viewModel.showSignalIndicators,
                            isInteractive: viewModel.isFaderInteractive,
                            usesWideLayout: true,
                            wideLayoutHeight: wideLayoutHeight,
                            onLevelChange: { level, channelID in
                                viewModel.setLevel(level, for: channelID)
                            },
                            onMuteToggle: { isMuted, channelID in
                                viewModel.setMute(isMuted, for: channelID)
                            }
                        )
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            AdaptiveMixerSurface(
                                channels: scrollableChannels,
                                showsSignalIndicators: viewModel.showSignalIndicators,
                                isInteractive: viewModel.isFaderInteractive,
                                usesWideLayout: false,
                                wideLayoutHeight: nil,
                                onLevelChange: { level, channelID in
                                    viewModel.setLevel(level, for: channelID)
                                },
                                onMuteToggle: { isMuted, channelID in
                                    viewModel.setMute(isMuted, for: channelID)
                                }
                            )
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(.systemGroupedBackground))
            .safeAreaInset(edge: .bottom) {
                if !usesWideMixerLayout, let mainLRChannel {
                    HorizontalMixerChannelRow(
                        channel: mainLRChannel,
                        showsSignalIndicator: viewModel.showSignalIndicators,
                        isInteractive: viewModel.isFaderInteractive,
                        onLevelChange: { level in
                            viewModel.setLevel(level, for: mainLRChannel.id)
                        },
                        onMuteToggle: { isMuted in
                            viewModel.setMute(isMuted, for: mainLRChannel.id)
                        }
                    )
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                    .background(.bar)
                }
            }
        }
    }
}

private struct ConnectionStatusCard: View {
    let title: String
    let message: String
    let phase: MixerConnectionPhase
    let isScanning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.headline)

                Spacer()

                StatusBadge(phase: phase)
            }

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if isScanning {
                ProgressView()
                    .progressViewStyle(.circular)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct StatusDetailsSheet: View {
    let title: String
    let message: String
    let phase: MixerConnectionPhase

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: statusIconName(for: phase))
                    .foregroundStyle(statusColor(for: phase))
                    .font(.title3)

                Text(title)
                    .font(.headline)

                Spacer()

                StatusBadge(phase: phase)
            }

            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .presentationCompactAdaptation(.none)
    }
}

private func statusLabel(for phase: MixerConnectionPhase) -> String {
    switch phase {
    case .connected: "Connected"
    case .connecting: "Connecting"
    case .disconnected: "Disconnected"
    case .error: "Error"
    }
}

private func statusIconName(for phase: MixerConnectionPhase) -> String {
    switch phase {
    case .connected: "checkmark.circle.fill"
    case .connecting: "arrow.triangle.2.circlepath.circle.fill"
    case .disconnected: "circle.dashed"
    case .error: "exclamationmark.circle.fill"
    }
}

private func statusColor(for phase: MixerConnectionPhase) -> Color {
    switch phase {
    case .connected: .green
    case .connecting: .orange
    case .disconnected: .secondary
    case .error: .red
    }
}

private struct StatusBadge: View {
    let phase: MixerConnectionPhase

    private var label: String {
        statusLabel(for: phase)
    }

    private var color: Color {
        statusColor(for: phase)
    }

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.14))
            .clipShape(Capsule())
    }
}

#Preview {
    ContentView(
        viewModel: MixerScreenViewModel(controller: MockMixerController()),
        isUsingMockConnection: true,
        onSetUseMockConnection: { _ in }
    )
}
