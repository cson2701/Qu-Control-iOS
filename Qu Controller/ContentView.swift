//
//  ContentView.swift
//  Qu Controller
//
//  Created by Chaoran Song on 12/7/2026.
//

import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: MixerScreenViewModel
    let isUsingMockConnection: Bool
    let onSetUseMockConnection: (Bool) -> Void

    @State private var isShowingSettings = false
    @State private var isShowingShutdownConfirmation = false

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.connectionState.phase == .connected {
                    connectedContent
                } else {
                    disconnectedContent
                }
            }
            .navigationTitle("Qu Controller")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
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

                    TextField("192.168.4.198", text: $viewModel.host)
                        .textInputAutocapitalization(.never)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.go)
                        .onSubmit {
                            if viewModel.connectionState.phase == .disconnected || viewModel.connectionState.phase == .error {
                                viewModel.toggleConnection()
                            }
                        }

                    Text("Port 51325")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ConnectionStatusCard(
                    title: "Status",
                    message: viewModel.statusMessage,
                    phase: viewModel.connectionState.phase,
                    isScanning: viewModel.isScanningForMixer
                )

                VStack(spacing: 12) {
                    Button(viewModel.buttonTitle) {
                        viewModel.toggleConnection()
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)

                    Button(viewModel.scanButtonTitle) {
                        if viewModel.isScanningForMixer {
                            viewModel.stopScanningForMixer()
                        } else {
                            viewModel.scanForMixer()
                        }
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                    .disabled(!viewModel.isScanningForMixer && !viewModel.isAutoScanAvailable)
                }
            }
            .frame(maxWidth: 560)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
    }

    private var connectedContent: some View {
        List {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(viewModel.statusMessage)
                            .font(.subheadline.weight(.medium))
                        Text("\(viewModel.visibleMainScreenChannels.count) visible channels")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    StatusBadge(phase: viewModel.connectionState.phase)
                }
                .padding(.vertical, 4)
            }

            Section("Channels") {
                ForEach(viewModel.visibleMainScreenChannels) { channel in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(channel.displayName)
                                    .font(.headline)
                                Text(channel.id.defaultDisplayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if viewModel.showSignalIndicators {
                                Circle()
                                    .fill(channel.hasSignal ? Color.green : Color.gray.opacity(0.4))
                                    .frame(width: 10, height: 10)
                            }
                        }

                        HStack {
                            Text("Level \(channel.level.percentage)%")
                                .font(.subheadline.monospacedDigit())

                            Spacer()

                            Toggle(
                                "Mute",
                                isOn: Binding(
                                    get: { channel.isMuted },
                                    set: { viewModel.setMute($0, for: channel.id) }
                                )
                            )
                            .labelsHidden()
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section {
                Button("Disconnect") {
                    viewModel.toggleConnection()
                }

                Button("Shut Down Mixer", role: .destructive) {
                    if viewModel.confirmBeforeShutdown {
                        isShowingShutdownConfirmation = true
                    } else {
                        viewModel.shutdownMixer()
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
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

private struct StatusBadge: View {
    let phase: MixerConnectionPhase

    private var label: String {
        switch phase {
        case .connected: "Connected"
        case .connecting: "Connecting"
        case .disconnected: "Disconnected"
        case .error: "Error"
        }
    }

    private var color: Color {
        switch phase {
        case .connected: .green
        case .connecting: .orange
        case .disconnected: .secondary
        case .error: .red
        }
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
