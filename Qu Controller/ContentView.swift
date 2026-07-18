//
//  ContentView.swift
//  Qu Controller
//
//  Created by Chaoran Song on 12/7/2026.
//

import Combine
import SwiftUI
import UIKit

struct ContentView: View {
    let viewModel: MixerScreenViewModel
    let isUsingMockConnection: Bool
    let transportMode: MixerTransportMode
    let onApplyConnectionMode: (ConnectionModeOption) -> Void

    @StateObject private var chromeModel: ContentChromeModel
    @State private var relayPortText: String
    @State private var isShowingSettings = false
    @State private var isShowingShutdownConfirmation = false
    @State private var isShowingStatusDetails = false
    @State private var isShowingConnectionHelp = false

    init(
        viewModel: MixerScreenViewModel,
        isUsingMockConnection: Bool,
        transportMode: MixerTransportMode,
        onApplyConnectionMode: @escaping (ConnectionModeOption) -> Void
    ) {
        self.viewModel = viewModel
        self.isUsingMockConnection = isUsingMockConnection
        self.transportMode = transportMode
        self.onApplyConnectionMode = onApplyConnectionMode
        _chromeModel = StateObject(wrappedValue: ContentChromeModel(viewModel: viewModel))
        _relayPortText = State(initialValue: String(viewModel.relayPort))
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
            .navigationTitle(isUsingMockConnection ? "Qu Controller Demo" : "Qu Controller")
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
                transportMode: transportMode,
                onApplyConnectionMode: onApplyConnectionMode
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
        .sheet(isPresented: $isShowingConnectionHelp) {
            ConnectionHelpSheet(transportMode: transportMode)
                .presentationDetents([.medium])
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
                    HStack(spacing: 8) {
                        Text(transportMode == .direct ? "Connect to a Qu mixer" : "Connect to Qu Controller Mac relay")
                            .font(.title2.weight(.semibold))

                        Button {
                            isShowingConnectionHelp = true
                        } label: {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 12) {
                    Text(transportMode == .direct ? "Mixer IP address" : "Relay IP address")
                        .font(.headline)

                    IPv4AddressTextField(
                        placeholder: chromeModel.hostPlaceholder,
                        text: hostBinding
                    ) {
                        if (chromeModel.connectionState.phase == .disconnected || chromeModel.connectionState.phase == .error)
                            && chromeModel.canConnect {
                            viewModel.toggleConnection(relayPortOverride: resolvedRelayPortOverride)
                        }
                    }
                    .frame(height: 36)

                    if transportMode == .relay {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Relay port")
                                .font(.headline)

                            DigitOnlyTextField(
                                placeholder: String(MixerTransportMode.relay.defaultEndpoint.port),
                                text: relayPortBinding
                            )
                            .frame(height: 36)

                            Text("Default port: 51326")
                                .font(.caption)
                                .foregroundStyle(Color.secondary)
                        }
                    } else {
                        Text("Port \(viewModel.currentPort)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                
                    HStack(spacing: 12) {
                        Button(chromeModel.buttonTitle) {
                            viewModel.toggleConnection(relayPortOverride: resolvedRelayPortOverride)
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                        .disabled(isPrimaryActionDisabled)

                        if chromeModel.supportsAutoDiscovery || chromeModel.isScanningForMixer {
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
                }

                ConnectionStatusCard(
                    title: "Status",
                    message: chromeModel.statusMessage,
                    phase: chromeModel.connectionState.phase,
                    isScanning: chromeModel.isScanningForMixer
                )
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
                chromeModel.host = newValue
                viewModel.updateHost(newValue)
            }
        )
    }

    private var relayPortBinding: Binding<String> {
        Binding(
            get: { relayPortText },
            set: { newValue in
                let sanitizedValue = newValue.filter(\.isWholeNumber)
                relayPortText = sanitizedValue

                if let port = Int(sanitizedValue), Self.isValidPort(port) {
                    viewModel.setRelayPort(port)
                }
            }
        )
    }

    private var isPrimaryActionDisabled: Bool {
        if transportMode == .relay && !isRelayPortValid {
            return true
        }

        return chromeModel.isPrimaryActionDisabled
    }

    private var isRelayPortValid: Bool {
        if relayPortText.isEmpty {
            return true
        }

        guard let port = Int(relayPortText) else {
            return false
        }

        return Self.isValidPort(port)
    }

    private var resolvedRelayPortOverride: Int? {
        guard transportMode == .relay else {
            return nil
        }

        if relayPortText.isEmpty {
            return MixerTransportMode.relay.defaultEndpoint.port
        }

        return Int(relayPortText)
    }

    private static func isValidPort(_ port: Int) -> Bool {
        (1 ... 65_535).contains(port)
    }
}

private struct ConnectionHelpSheet: View {
    let transportMode: MixerTransportMode

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(transportMode == .direct ? "Connect to a Qu mixer" : "Connect to Qu Controller Mac relay")
                            .font(.title3.weight(.semibold))

                        Text(
                            transportMode == .direct
                                ? "Enter the mixer IP address directly or scan the local network to find it."
                                : "Enter the Mac's LAN IP address and the relay port configured in Qu Controller Mac Settings."
                        )
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(transportMode == .direct ? "Where to find the mixer IP address" : "What to enter for relay mode")
                            .font(.headline)

                        if transportMode == .direct {
                            Text("On the mixer, press the physical **Setup** button, then on the touchscreen tap **Utility** > **Diagnostics**. Locate the current IP address.")
                                .foregroundStyle(.secondary)

                            Text(.init("To set up the IP address, press the **Setup** button, then tap **Control** > **Network**. See page 68 of the [Qu Mixer Reference Guide](https://www.allen-heath.com/content/uploads/2023/06/Qu-Mixer-Reference-Guide-AP9372_10.pdf) for more detail."))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Use the IP address of the Mac running Qu Controller Mac, not the mixer IP address.")
                                .foregroundStyle(.secondary)

                            Text("Use the relay port shown in Qu Controller Mac Settings. The default relay port is 51326.")
                                .foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Tip")
                            .font(.headline)

                        Text(
                            transportMode == .direct
                                ? "If you do not know the address, use Find Mixer to scan the local network automatically."
                                : "Relay mode does not support mixer discovery. Make sure the Mac relay is enabled and reachable on the local network."
                        )
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .navigationTitle("Connection Help")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct IPv4AddressTextField: UIViewRepresentable {
    let placeholder: String
    @Binding var text: String
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    func makeUIView(context: Context) -> UITextField {
        let textField = UITextField(frame: .zero)
        textField.borderStyle = .roundedRect
        textField.keyboardType = .decimalPad
        textField.returnKeyType = .go
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.clearButtonMode = .whileEditing
        textField.delegate = context.coordinator
        textField.addTarget(context.coordinator, action: #selector(Coordinator.textDidChange(_:)), for: .editingChanged)
        return textField
    }

    func updateUIView(_ textField: UITextField, context: Context) {
        textField.placeholder = placeholder
        if textField.text != text {
            textField.text = text
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        @Binding private var text: String
        private let onSubmit: () -> Void

        init(text: Binding<String>, onSubmit: @escaping () -> Void) {
            _text = text
            self.onSubmit = onSubmit
        }

        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString: String) -> Bool {
            let currentText = textField.text ?? ""
            guard let stringRange = Range(range, in: currentText) else {
                return false
            }

            let proposedText = currentText.replacingCharacters(in: stringRange, with: replacementString)
            return ContentChromeModel.isAllowedIPv4Input(proposedText)
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            onSubmit()
            return true
        }

        @objc func textDidChange(_ textField: UITextField) {
            text = textField.text ?? ""
        }
    }
}

private struct DigitOnlyTextField: UIViewRepresentable {
    let placeholder: String
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> UITextField {
        let textField = UITextField(frame: .zero)
        textField.borderStyle = .roundedRect
        textField.keyboardType = .numberPad
        textField.clearButtonMode = .whileEditing
        textField.delegate = context.coordinator
        textField.addTarget(context.coordinator, action: #selector(Coordinator.textDidChange(_:)), for: .editingChanged)
        return textField
    }

    func updateUIView(_ textField: UITextField, context: Context) {
        textField.placeholder = placeholder
        if textField.text != text {
            textField.text = text
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        @Binding private var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString: String) -> Bool {
            replacementString.allSatisfy(\.isWholeNumber) || replacementString.isEmpty
        }

        @objc func textDidChange(_ textField: UITextField) {
            text = textField.text ?? ""
        }
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

    let supportsAutoDiscovery: Bool
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

    static func isAllowedIPv4Input(_ value: String) -> Bool {
        if value.isEmpty {
            return true
        }

        guard value.allSatisfy({ $0.isWholeNumber || $0 == "." }),
              !value.hasPrefix("."),
              !value.contains("..") else {
            return false
        }

        let octets = value.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count <= 4 else {
            return false
        }

        for octet in octets {
            guard octet.count <= 3 else {
                return false
            }

            if !octet.isEmpty {
                guard let octetValue = Int(octet), octetValue <= 255 else {
                    return false
                }
            }
        }

        return true
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

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(
            viewModel: MixerScreenViewModel(
                controllerMode: .mock,
                transportMode: .direct,
                controller: MockMixerController()
            ),
            isUsingMockConnection: true,
            transportMode: .direct,
            onApplyConnectionMode: { _ in }
        )
    }
}
