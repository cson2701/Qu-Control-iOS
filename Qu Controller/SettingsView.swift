import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: MixerScreenViewModel
    let isUsingMockConnection: Bool
    let onSetUseMockConnection: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
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

                    Toggle(
                        "Automatically connect after discovery",
                        isOn: Binding(
                            get: { viewModel.autoConnectAfterDiscovery },
                            set: viewModel.setAutoConnectAfterDiscovery(_:)
                        )
                    )
                    
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
                Section("Debug") {
                    Toggle(
                        "Use Mock Connection",
                        isOn: Binding(
                            get: { isUsingMockConnection },
                            set: onSetUseMockConnection
                        )
                    )
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
