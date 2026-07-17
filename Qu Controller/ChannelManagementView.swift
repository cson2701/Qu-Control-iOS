import SwiftUI

struct ChannelManagementView: View {
    @ObservedObject var viewModel: MixerScreenViewModel
    let surface: MixerLayoutSurface

    var body: some View {
        List {
            Section {
                ForEach(viewModel.selectableChannels) { channel in
                    ChannelManagementRow(
                        channel: channel,
                        isVisible: Binding(
                            get: { viewModel.isChannelVisible(channel.id, on: surface) },
                            set: { viewModel.setChannelVisibility($0, for: channel.id, on: surface) }
                        )
                    )
                }
                .onMove { source, destination in
                    viewModel.moveSelectableChannels(fromOffsets: source, toOffset: destination, on: surface)
                }
            } footer: {
                Text("Turn on channels to show them on the mixer screen. Use Edit to reorder them.")
            }

            Section {
                Button("Reset Order", role: .destructive) {
                    viewModel.resetChannelOrder(on: surface)
                }
                .disabled(!canResetOrder)
            }
        }
        .navigationTitle("Visible Channels")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
    }

    private var canResetOrder: Bool {
        viewModel.layoutPreferences.orderedChannelIDs(for: surface) != MixerLayoutPreferences.default.orderedChannelIDs(for: surface)
    }
}

private struct ChannelManagementRow: View {
    let channel: MixerChannelState
    @Binding var isVisible: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: showsSubtitle ? 2 : 0) {
                Text(channel.displayName)
                    .font(.body)

                if showsSubtitle {
                    Text(channel.id.defaultDisplayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Toggle("", isOn: $isVisible)
                .labelsHidden()
                .disabled(isVisibilityLocked)
        }
    }

    private var showsSubtitle: Bool {
        channel.displayName != channel.id.defaultDisplayName
    }

    private var isVisibilityLocked: Bool {
        channel.id == .mainLr
    }
}
