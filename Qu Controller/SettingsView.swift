import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: MixerScreenViewModel
    let isUsingMockConnection: Bool
    let transportMode: MixerTransportMode
    let onSetUseMockConnection: (Bool) -> Void
    let onSetTransportMode: (MixerTransportMode) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Transport") {
                    Picker(
                        "Connection type",
                        selection: Binding(
                            get: { transportMode },
                            set: onSetTransportMode
                        )
                    ) {
                        ForEach(MixerTransportMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    if transportMode == .relay {
                        Text("Relay mode connects to Qu-Control-Mac instead of opening a direct mixer TCP socket.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if transportMode == .relay {
                    Section("Relay Connection") {
                        TextField(
                            "Relay IP address",
                            text: Binding(
                                get: { viewModel.host },
                                set: viewModel.updateHost(_:)
                            )
                        )
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                        TextField(
                            "Port",
                            value: Binding(
                                get: { viewModel.relayPort },
                                set: viewModel.setRelayPort(_:)
                            ),
                            format: .number.grouping(.never)
                        )
                        .keyboardType(.numberPad)

                        Text("The default relay port is 51326.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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

                    Toggle(
                        "Scan for mixer on launch",
                        isOn: Binding(
                            get: { viewModel.autoScanOnLaunch },
                            set: viewModel.setAutoScanOnLaunch(_:)
                        )
                    )
                    .disabled(transportMode != .direct)

                    Toggle(
                        "Automatically connect after discovery",
                        isOn: Binding(
                            get: { viewModel.autoConnectAfterDiscovery },
                            set: viewModel.setAutoConnectAfterDiscovery(_:)
                        )
                    )
                    .disabled(transportMode != .direct)
                    
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

#if DEBUG
                if viewModel.connectionState.phase != .connected {
                    Section {
                        Toggle(
                            "Demo Mode",
                            isOn: Binding(
                                get: { isUsingMockConnection },
                                set: onSetUseMockConnection
                            )
                        )
                    }
                }
#endif
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
        }
    }
}
