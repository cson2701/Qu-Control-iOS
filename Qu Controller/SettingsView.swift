import SwiftUI

enum ConnectionModeOption: String, CaseIterable, Equatable, Identifiable {
    case mixer
    case relay
    case demo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mixer:
            "Mixer"
        case .relay:
            "Relay"
        case .demo:
            "Demo"
        }
    }

    init(isUsingMockConnection: Bool, transportMode: MixerTransportMode) {
        if isUsingMockConnection {
            self = .demo
        } else {
            self = switch transportMode {
            case .direct:
                .mixer
            case .relay:
                .relay
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var viewModel: MixerScreenViewModel
    let isUsingMockConnection: Bool
    let transportMode: MixerTransportMode
    let onApplyConnectionMode: (ConnectionModeOption) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draftConnectionMode: ConnectionModeOption
    @State private var hasAppliedDraftConnectionMode = false

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
        _draftConnectionMode = State(
            initialValue: ConnectionModeOption(
                isUsingMockConnection: isUsingMockConnection,
                transportMode: transportMode
            )
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(
                        "Connection mode",
                        selection: $draftConnectionMode
                    ) {
                        ForEach(ConnectionModeOption.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                } footer: {
                    if draftConnectionMode == .relay {
                        Text("Relay mode connects to Qu Controller Mac instead of opening a direct mixer TCP socket.")
                    }
                }

                Section {
                    Toggle(
                        "Automatically connect to last known IP address",
                        isOn: Binding(
                            get: { viewModel.autoConnectLastKnownHostOnLaunch },
                            set: viewModel.setAutoConnectLastKnownHostOnLaunch(_:)
                        )
                    )

                    if draftConnectionMode == .mixer {
                        Toggle(
                            "Scan for mixer on launch",
                            isOn: Binding(
                                get: { viewModel.autoScanOnLaunch },
                                set: viewModel.setAutoScanOnLaunch(_:)
                            )
                        )

                        Toggle(
                            "Automatically connect after discovery",
                            isOn: Binding(
                                get: { viewModel.autoConnectAfterDiscovery },
                                set: viewModel.setAutoConnectAfterDiscovery(_:)
                            )
                        )
                    }
                    
                    Toggle(
                        "Confirm before shutting down",
                        isOn: Binding(
                            get: { viewModel.confirmBeforeShutdown },
                            set: viewModel.setConfirmBeforeShutdown(_:)
                        )
                    )
                }

                Section {
                    Toggle(
                        "Show signal indicators",
                        isOn: Binding(
                            get: { viewModel.showSignalIndicators },
                            set: viewModel.setShowSignalIndicators(_:)
                        )
                    )

                    if viewModel.connectionState.phase == .connected {
                        NavigationLink("Manage Channels") {
                            ChannelManagementView(viewModel: viewModel, surface: .mainScreen)
                        }
                    }
                }

            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .onDisappear {
                applyDraftConnectionModeIfNeeded()
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        applyDraftConnectionModeIfNeeded()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
        }
    }

    private func applyDraftConnectionModeIfNeeded() {
        guard !hasAppliedDraftConnectionMode else {
            return
        }

        hasAppliedDraftConnectionMode = true
        onApplyConnectionMode(draftConnectionMode)
    }
}
