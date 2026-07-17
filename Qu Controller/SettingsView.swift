import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: MixerScreenViewModel
    let isUsingMockConnection: Bool
    let onSetUseMockConnection: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    Toggle(
                        "Automatically connect after discovery",
                        isOn: Binding(
                            get: { viewModel.autoConnectAfterDiscovery },
                            set: viewModel.setAutoConnectAfterDiscovery(_:)
                        )
                    )
                }

                Section("Safety") {
                    Toggle(
                        "Confirm before shutting down",
                        isOn: Binding(
                            get: { viewModel.confirmBeforeShutdown },
                            set: viewModel.setConfirmBeforeShutdown(_:)
                        )
                    )
                }

                Section("Display") {
                    Toggle(
                        "Show signal indicators",
                        isOn: Binding(
                            get: { viewModel.showSignalIndicators },
                            set: viewModel.setShowSignalIndicators(_:)
                        )
                    )
                }

                Section("Visible Channels") {
                    NavigationLink("Manage Channels") {
                        ChannelManagementView(viewModel: viewModel, surface: .mainScreen)
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .tint(.primary)
                }
            }
        }
    }
}
