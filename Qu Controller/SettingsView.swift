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
    @ObservedObject var homeKitService: HomeKitSmartPlugService
    let isUsingMockConnection: Bool
    let transportMode: MixerTransportMode
    let onApplyConnectionMode: (ConnectionModeOption) -> Void
    let onResetApp: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draftConnectionMode: ConnectionModeOption
    @State private var hasAppliedDraftConnectionMode = false
    @State private var isShowingResetConfirmation = false

    init(
        viewModel: MixerScreenViewModel,
        homeKitService: HomeKitSmartPlugService,
        isUsingMockConnection: Bool,
        transportMode: MixerTransportMode,
        onApplyConnectionMode: @escaping (ConnectionModeOption) -> Void,
        onResetApp: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        _homeKitService = ObservedObject(wrappedValue: homeKitService)
        self.isUsingMockConnection = isUsingMockConnection
        self.transportMode = transportMode
        self.onApplyConnectionMode = onApplyConnectionMode
        self.onResetApp = onResetApp
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
                        "Turn off smart plug after shutdown",
                        isOn: Binding(
                            get: { homeKitService.isAutomaticPowerOffEnabled },
                            set: homeKitService.setAutomaticPowerOffEnabled(_:)
                        )
                    )

                    if homeKitService.isAutomaticPowerOffEnabled {
                        if homeKitService.isLoading {
                            HStack {
                                Text("Loading smart plugs")
                                Spacer()
                                ProgressView()
                            }
                        } else {
                            Picker(
                                "Smart plug",
                                selection: Binding(
                                    get: { homeKitService.selectedPlugID },
                                    set: homeKitService.selectPlug(withID:)
                                )
                            ) {
                                Text("Select a plug").tag(String?.none)
                                if let selectedPlugID = homeKitService.selectedPlugID,
                                   !homeKitService.availablePlugs.contains(where: { $0.id == selectedPlugID }) {
                                    Text("\(homeKitService.selectedPlugName ?? "Selected plug") (Unavailable)")
                                        .tag(Optional(selectedPlugID))
                                }
                                ForEach(homeKitService.availablePlugs) { plug in
                                    VStack(alignment: .leading) {
                                        Text(plug.name)
                                        if !plug.location.isEmpty {
                                            Text(plug.location)
                                        }
                                    }
                                    .tag(Optional(plug.id))
                                }
                            }

                            Button("Refresh Smart Plugs") {
                                homeKitService.loadPlugs()
                            }
                        }

                        if homeKitService.hasSelectedPlug {
                            HStack {
                                Toggle(
                                    "Manual plug power",
                                    isOn: Binding(
                                        get: { homeKitService.selectedPlugIsOn ?? false },
                                        set: homeKitService.setSelectedPlugPower(_:)
                                    )
                                )
                                .disabled(
                                    homeKitService.selectedPlugIsOn == nil
                                        || homeKitService.isUpdatingPlugPower
                                )

                                if homeKitService.isUpdatingPlugPower {
                                    ProgressView()
                                }
                            }
                        }

                        Stepper(
                            "Power-off delay: \(homeKitService.delaySeconds) sec",
                            value: Binding(
                                get: { homeKitService.delaySeconds },
                                set: homeKitService.setDelaySeconds(_:)
                            ),
                            in: 0 ... 5,
                            step: 1
                        )

                        if let errorMessage = homeKitService.errorMessage {
                            Text(errorMessage)
                                .foregroundStyle(.red)
                        } else {
                            Text(homeKitService.authorizationDescription)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("HomeKit Power")
                } footer: {
                    Text("After the mixer accepts its shutdown command, Qu Controller waits for the selected delay before turning off the plug. The plug stays on if the mixer command fails.")
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

                Section {
                    Button("Reset App", role: .destructive) {
                        isShowingResetConfirmation = true
                    }
                } footer: {
                    Text("Clears saved mixer addresses, connection settings, channel layout, and all other app preferences.")
                }

            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .onDisappear {
                applyDraftConnectionModeIfNeeded()
            }
            .onAppear {
                if homeKitService.isAutomaticPowerOffEnabled || homeKitService.hasSelectedPlug {
                    homeKitService.loadPlugs()
                }
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
            .confirmationDialog(
                "Reset Qu Controller?",
                isPresented: $isShowingResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Reset App", role: .destructive) {
                    hasAppliedDraftConnectionMode = true
                    dismiss()
                    onResetApp()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This restores the app to its first-launch settings. Local network permission remains controlled by iOS Settings.")
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
