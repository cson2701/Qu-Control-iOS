import SwiftUI

struct AdaptiveMixerSurface: View {
    let channels: [MixerChannelState]
    let showsSignalIndicators: Bool
    let isInteractive: Bool
    let usesWideLayout: Bool
    let wideLayoutHeight: CGFloat?
    let onLevelChange: (FaderLevel, MixerChannelID) -> Void
    let onMuteToggle: (Bool, MixerChannelID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if channels.isEmpty {
                emptyState
            } else if usesWideLayout {
                wideLayout
            } else {
                compactLayout
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var mainLRChannel: MixerChannelState? {
        channels.first(where: { $0.id == .mainLr })
    }

    private var scrollableChannels: [MixerChannelState] {
        channels.filter { $0.id != .mainLr }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(.secondary)

            Text("No channels selected")
                .font(.headline)

            Text("Choose visible channels in Settings.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var compactLayout: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVStack(spacing: 12) {
                ForEach(scrollableChannels) { channel in
                    HorizontalMixerChannelRow(
                        channel: channel,
                        showsSignalIndicator: showsSignalIndicators,
                        isInteractive: isInteractive,
                        onLevelChange: { level in
                            onLevelChange(level, channel.id)
                        },
                        onMuteToggle: { isMuted in
                            onMuteToggle(isMuted, channel.id)
                        }
                    )
                }
            }

            if let mainLRChannel {
                HorizontalMixerChannelRow(
                    channel: mainLRChannel,
                    showsSignalIndicator: showsSignalIndicators,
                    isInteractive: isInteractive,
                    onLevelChange: { level in
                        onLevelChange(level, mainLRChannel.id)
                    },
                    onMuteToggle: { isMuted in
                        onMuteToggle(isMuted, mainLRChannel.id)
                    }
                )
            }
        }
    }

    private var wideLayout: some View {
        HStack(alignment: .top, spacing: 14) {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(scrollableChannels) { channel in
                        VerticalMixerChannelCard(
                            channel: channel,
                            availableHeight: wideCardHeight,
                            showsSignalIndicator: showsSignalIndicators,
                            isInteractive: isInteractive,
                            onLevelChange: { level in
                                onLevelChange(level, channel.id)
                            },
                            onMuteToggle: { isMuted in
                                onMuteToggle(isMuted, channel.id)
                            }
                        )
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.visible)

            if let mainLRChannel {
                VerticalMixerChannelCard(
                    channel: mainLRChannel,
                    availableHeight: wideCardHeight,
                    showsSignalIndicator: showsSignalIndicators,
                    isInteractive: isInteractive,
                    onLevelChange: { level in
                        onLevelChange(level, mainLRChannel.id)
                    },
                    onMuteToggle: { isMuted in
                        onMuteToggle(isMuted, mainLRChannel.id)
                    }
                )
            }
        }
    }

    private var wideCardHeight: CGFloat {
        guard let wideLayoutHeight else {
            return 300
        }

        return max(220, wideLayoutHeight - 56)
    }
}

struct HorizontalMixerChannelRow: View {
    let channel: MixerChannelState
    let showsSignalIndicator: Bool
    let isInteractive: Bool
    let onLevelChange: (FaderLevel) -> Void
    let onMuteToggle: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.displayName)
                        .font(.headline)

                    Text(channel.id.defaultDisplayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if showsSignalIndicator {
                    Circle()
                        .fill(isInteractive && channel.hasSignal ? Color.green : Color.gray.opacity(0.35))
                        .frame(width: 10, height: 10)
                }

                HStack(alignment: .center, spacing: 8) {
                    Text("\(isInteractive ? channel.level.percentage : 0)%")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(isInteractive ? Color.primary : Color.secondary)
                        .frame(minWidth: 44, alignment: .trailing)

                    MuteChipButton(isMuted: channel.isMuted, action: {
                        onMuteToggle(!channel.isMuted)
                    }, label: "Mute")
                    .disabled(!isInteractive)
                }
            }

            HorizontalLevelSlider(
                value: channel.level.normalized,
                isEnabled: isInteractive,
                onValueChange: { normalized in
                    onLevelChange(FaderLevel(normalized: normalized))
                }
            )
            .frame(height: 34)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct VerticalMixerChannelCard: View {
    let channel: MixerChannelState
    let availableHeight: CGFloat
    let showsSignalIndicator: Bool
    let isInteractive: Bool
    let onLevelChange: (FaderLevel) -> Void
    let onMuteToggle: (Bool) -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                if showsSignalIndicator {
                    Circle()
                        .fill(isInteractive && channel.hasSignal ? Color.green : Color.gray.opacity(0.35))
                        .frame(width: 8, height: 8)
                }

                Text(channel.displayName)
                    .font(.headline.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(height: 44)

            HStack(alignment: .center, spacing: 8) {
                Text(isInteractive ? "\(channel.level.percentage)%" : "--")
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(isInteractive ? Color.accentColor : Color.secondary)

                MuteChipButton(isMuted: channel.isMuted, action: {
                    onMuteToggle(!channel.isMuted)
                }, label: "M")
                .disabled(!isInteractive)
            }

            VerticalLevelSlider(
                value: channel.level.normalized,
                isEnabled: isInteractive,
                onValueChange: { normalized in
                    onLevelChange(FaderLevel(normalized: normalized))
                }
            )
            .frame(width: 54)
            .frame(maxHeight: .infinity)
        }
        .frame(width: 102, height: availableHeight, alignment: .top)
        .padding(.horizontal, 6)
        .padding(.vertical, 16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct MuteChipButton: View {
    let isMuted: Bool
    let action: () -> Void
    let label: String

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isMuted ? Color.white : Color.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isMuted ? Color.red : Color.primary.opacity(0.08))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct HorizontalLevelSlider: View {
    let value: Double
    let isEnabled: Bool
    let onValueChange: (Double) -> Void

    @State private var sliderValue: Double

    var body: some View {
        Slider(
            value: Binding(
                get: { sliderValue },
                set: { newValue in
                    sliderValue = newValue
                    onValueChange(newValue)
                }
            ),
            in: 0 ... 1
        )
        .disabled(!isEnabled)
        .tint(.accentColor)
        .onChange(of: value) { _, newValue in
            sliderValue = newValue
        }
        .opacity(isEnabled ? 1 : 0.55)
        .onAppear {
            sliderValue = value
        }
    }

    init(value: Double, isEnabled: Bool, onValueChange: @escaping (Double) -> Void) {
        self.value = value
        self.isEnabled = isEnabled
        self.onValueChange = onValueChange
        _sliderValue = State(initialValue: value)
    }
}

private struct VerticalLevelSlider: View {
    let value: Double
    let isEnabled: Bool
    let onValueChange: (Double) -> Void

    @State private var sliderValue: Double

    var body: some View {
        GeometryReader { proxy in
            Slider(
                value: Binding(
                    get: { sliderValue },
                    set: { newValue in
                        sliderValue = newValue
                        onValueChange(newValue)
                    }
                ),
                in: 0 ... 1
            )
            .disabled(!isEnabled)
            .tint(.accentColor)
            .rotationEffect(.degrees(-90))
            .frame(width: proxy.size.height, height: 34)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            .onChange(of: value) { _, newValue in
                sliderValue = newValue
            }
            .opacity(isEnabled ? 1 : 0.55)
        }
        .onAppear {
            sliderValue = value
        }
    }

    init(value: Double, isEnabled: Bool, onValueChange: @escaping (Double) -> Void) {
        self.value = value
        self.isEnabled = isEnabled
        self.onValueChange = onValueChange
        _sliderValue = State(initialValue: value)
    }
}
