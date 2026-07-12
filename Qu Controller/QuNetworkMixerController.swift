//
//  QuNetworkMixerController.swift
//  Qu Controller
//

import Combine
import Foundation
import Network

// Protocol reference:
// docs/IMPLEMENTATION_REFERENCES.md
@MainActor
final class QuNetworkMixerController: MixerController {
    @Published private var storedChannels: [MixerChannelState] = QuNetworkMixerController.makeInitialChannels()
    @Published private var storedConnectionState = MixerConnectionState(
        phase: .disconnected,
        message: "Disconnected",
        endpoint: nil
    )

    var channels: [MixerChannelState] {
        storedChannels
    }

    var connectionState: MixerConnectionState {
        storedConnectionState
    }

    var channelsPublisher: AnyPublisher<[MixerChannelState], Never> {
        $storedChannels.eraseToAnyPublisher()
    }

    var connectionStatePublisher: AnyPublisher<MixerConnectionState, Never> {
        $storedConnectionState.eraseToAnyPublisher()
    }

    private let connectionQueue = DispatchQueue(label: "com.scrapps.qucontroller.network")
    private let connectionTimeout: Duration = .seconds(5)
    private let signalPublishInterval: Duration = .milliseconds(300)
    private var connection: NWConnection?
    private var activeSenseTask: Task<Void, Never>?
    private var connectionTimeoutTask: Task<Void, Never>?
    private var signalPublishTask: Task<Void, Never>?
    private var midiChannel: UInt8?
    private var mixerModel: QuMixerModel?
    private var byteBuffer: [UInt8] = []
    private var nrpnState = NRPNState()
    private var isIntentionalDisconnect = false
    private var isSignalMonitoringEnabled = false
    private var pendingSignalStates: [MixerChannelID: Bool] = [:]

    func connect(to endpoint: MixerEndpoint) async {
        await disconnectTransport(updateState: false, intentional: false)
        isIntentionalDisconnect = false

        storedConnectionState = MixerConnectionState(
            phase: .connecting,
            message: "Connecting to \(endpoint.host):\(endpoint.port)",
            endpoint: endpoint
        )
        startConnectionTimeout(for: endpoint)

        do {
            let nwConnection = try await makeConnection(for: endpoint)
            connection = nwConnection
            startReceiving(on: nwConnection, endpoint: endpoint)
            startActiveSensing()
            try await sendSystemStateRequest()
        } catch {
            await handleConnectionFailure(error, endpoint: endpoint, prefix: "Connection failed")
        }
    }

    func disconnect() {
        Task {
            await disconnectTransport(updateState: true, intentional: true)
        }
    }

    func shutdownMixer() async {
        guard connectionState.phase == .connected, let midiChannel else {
            storedConnectionState = MixerConnectionState(
                phase: .error,
                message: "Shutdown unavailable: Connect to a mixer first",
                endpoint: storedConnectionState.endpoint
            )
            return
        }

        do {
            try await sendRemoteShutdown(midiChannel: midiChannel)
            let endpoint = storedConnectionState.endpoint
            await disconnectTransport(updateState: false, intentional: true)
            storedConnectionState = MixerConnectionState(
                phase: .disconnected,
                message: "Shutdown command sent. Mixer is powering off.",
                endpoint: endpoint
            )
        } catch {
            await handleConnectionFailure(error, endpoint: storedConnectionState.endpoint, prefix: "Shutdown failed")
        }
    }

    func setLevel(for channelID: MixerChannelID, level: FaderLevel) {
        storedChannels = storedChannels.map { channel in
            guard channel.id == channelID else {
                return channel
            }
            return MixerChannelState(
                id: channel.id,
                level: level,
                isMuted: channel.isMuted,
                hasSignal: channel.hasSignal,
                customName: channel.customName
            )
        }

        guard let midiChannel else {
            return
        }

        Task {
            do {
                try await sendNRPN(
                    midiChannel: midiChannel,
                    targetChannel: channelID.midiChannelCode,
                    parameterID: 0x17,
                    value: UInt8(level.toMIDIValue()),
                    index: 0x07
                )
            } catch {
                await handleConnectionFailure(
                    error,
                    endpoint: storedConnectionState.endpoint,
                    prefix: "Send failed"
                )
            }
        }
    }

    func setMute(for channelID: MixerChannelID, isMuted: Bool) {
        storedChannels = storedChannels.map { channel in
            guard channel.id == channelID else {
                return channel
            }

            return MixerChannelState(
                id: channel.id,
                level: channel.level,
                isMuted: isMuted,
                hasSignal: channel.hasSignal,
                customName: channel.customName
            )
        }

        guard let midiChannel else {
            return
        }

        Task {
            do {
                try await sendMute(
                    midiChannel: midiChannel,
                    targetChannel: channelID.midiChannelCode,
                    isMuted: isMuted
                )
            } catch {
                await handleConnectionFailure(
                    error,
                    endpoint: storedConnectionState.endpoint,
                    prefix: "Send failed"
                )
            }
        }
    }

    func setSignalMonitoringEnabled(_ isEnabled: Bool) {
        guard isSignalMonitoringEnabled != isEnabled else {
            return
        }

        isSignalMonitoringEnabled = isEnabled

        Task {
            do {
                try await sendMeterRequest(isEnabled: isEnabled)
                if !isEnabled {
                    clearSignalStates()
                }
            } catch {
                if isEnabled {
                    await handleConnectionFailure(
                        error,
                        endpoint: storedConnectionState.endpoint,
                        prefix: "Signal monitoring failed"
                    )
                } else {
                    clearSignalStates()
                }
            }
        }
    }

    private func makeConnection(for endpoint: MixerEndpoint) async throws -> NWConnection {
        guard let port = NWEndpoint.Port(rawValue: UInt16(endpoint.port)) else {
            throw MixerTransportError.invalidPort(endpoint.port)
        }

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        let nwConnection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: port, using: parameters)

        return try await withCheckedThrowingContinuation { continuation in
            let startState = ConnectionStartState()

            nwConnection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if startState.markResumed() {
                        continuation.resume(returning: nwConnection)
                    }
                case .failed(let error):
                    Task { @MainActor in
                        guard let self else { return }
                        if startState.markResumed() {
                            continuation.resume(throwing: error)
                        } else {
                            await self.handleConnectionFailure(error, endpoint: endpoint, prefix: "Connection lost")
                        }
                    }
                case .cancelled:
                    if startState.markResumed() {
                        continuation.resume(throwing: MixerTransportError.cancelledBeforeReady)
                    }
                default:
                    break
                }
            }

            nwConnection.start(queue: connectionQueue)
        }
    }

    private func startReceiving(on nwConnection: NWConnection, endpoint: MixerEndpoint) {
        nwConnection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            Task { @MainActor in
                if let error {
                    await self.handleConnectionFailure(error, endpoint: endpoint, prefix: "Connection lost")
                    return
                }

                if let data, !data.isEmpty {
                    self.byteBuffer.append(contentsOf: data)
                    self.processBufferedMessages(endpoint: endpoint)
                }

                if isComplete {
                    await self.handleConnectionFailure(
                        MixerTransportError.connectionClosed,
                        endpoint: endpoint,
                        prefix: "Connection lost"
                    )
                    return
                }

                if self.connection === nwConnection {
                    self.startReceiving(on: nwConnection, endpoint: endpoint)
                }
            }
        }
    }

    private func processBufferedMessages(endpoint: MixerEndpoint) {
        while let firstByte = byteBuffer.first {
            switch firstByte {
            case 0xFE:
                byteBuffer.removeFirst()
            case 0xF0:
                guard let endIndex = byteBuffer.firstIndex(of: 0xF7) else {
                    return
                }
                let sysex = Array(byteBuffer[...endIndex])
                byteBuffer.removeSubrange(...endIndex)
                handleSysEx(sysex, endpoint: endpoint)
            case 0xB0 ... 0xBF:
                guard byteBuffer.count >= 3 else {
                    return
                }
                let status = byteBuffer[0]
                let controller = byteBuffer[1]
                let value = byteBuffer[2]
                byteBuffer.removeFirst(3)
                handleControlChange(status: status, controller: controller, value: value)
            case 0x80 ... 0x9F:
                guard byteBuffer.count >= 3 else {
                    return
                }
                let status = byteBuffer[0]
                let note = byteBuffer[1]
                let velocity = byteBuffer[2]
                byteBuffer.removeFirst(3)
                handleNoteMessage(status: status, note: note, velocity: velocity)
            default:
                byteBuffer.removeFirst()
            }
        }
    }

    private func startActiveSensing() {
        activeSenseTask?.cancel()
        activeSenseTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                do {
                    try await self.sendBytes([0xFE])
                } catch {
                    await self.handleConnectionFailure(
                        error,
                        endpoint: self.storedConnectionState.endpoint,
                        prefix: "Connection lost"
                    )
                    return
                }

                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func sendSystemStateRequest() async throws {
        try await sendBytes([0xF0, 0x00, 0x00, 0x1A, 0x50, 0x11, 0x01, 0x00, 0x7F, 0x10, 0x01, 0xF7])
    }

    private func requestChannelNames() async throws {
        guard let midiChannel else {
            return
        }

        for channelID in MixerChannelID.selectableChannels {
            try await sendBytes([
                0xF0, 0x00, 0x00, 0x1A, 0x50, 0x11, 0x01, 0x00, midiChannel, 0x01, channelID.midiChannelCode, 0xF7
            ])
        }
    }

    private func sendMeterRequest(isEnabled: Bool) async throws {
        guard connection != nil else {
            if !isEnabled {
                clearSignalStates()
                return
            }
            throw MixerTransportError.notConnected
        }

        let requestChannel = midiChannel ?? 0x7F
        try await sendBytes([0xF0, 0x00, 0x00, 0x1A, 0x50, 0x11, 0x01, 0x00, requestChannel, 0x12, isEnabled ? 0x01 : 0x00, 0xF7])
    }

    private func sendNRPN(
        midiChannel: UInt8,
        targetChannel: UInt8,
        parameterID: UInt8,
        value: UInt8,
        index: UInt8
    ) async throws {
        let status = 0xB0 | midiChannel
        try await sendBytes([
            status, 0x63, targetChannel,
            status, 0x62, parameterID,
            status, 0x06, value,
            status, 0x26, index
        ])
    }

    private func sendMute(midiChannel: UInt8, targetChannel: UInt8, isMuted: Bool) async throws {
        let status = 0x90 | midiChannel
        try await sendBytes([
            status, targetChannel, isMuted ? 0x7F : 0x3F,
            status, targetChannel, 0x00
        ])
    }

    private func sendRemoteShutdown(midiChannel: UInt8) async throws {
        let status = 0xB0 | midiChannel
        try await sendBytes([
            status, 0x63, 0x00,
            status, 0x62, 0x5F,
            status, 0x06, 0x00,
            status, 0x26, 0x00
        ])
    }

    private func sendBytes(_ bytes: [UInt8]) async throws {
        guard let connection else {
            throw MixerTransportError.notConnected
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(bytes), completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }

    private func handleSysEx(_ bytes: [UInt8], endpoint: MixerEndpoint) {
        guard bytes.count >= 10 else {
            return
        }

        let isQuHeader =
            bytes[0] == 0xF0 &&
            bytes[1] == 0x00 &&
            bytes[2] == 0x00 &&
            bytes[3] == 0x1A &&
            bytes[4] == 0x50 &&
            bytes[5] == 0x11

        guard isQuHeader else {
            return
        }

        let receivedMIDIChannel = bytes[8] & 0x0F
        let command = bytes[9] & 0x7F

        switch command {
        case 0x02:
            guard bytes.count >= 12,
                  let channelID = MixerChannelID(midiChannelCode: bytes[10]) else {
                return
            }

            let nameBytes = Array(bytes[11..<(bytes.count - 1)])
            let decodedName = sanitizedChannelName(from: nameBytes)

            storedChannels = storedChannels.map { channel in
                guard channel.id == channelID else {
                    return channel
                }

                return MixerChannelState(
                    id: channel.id,
                    level: channel.level,
                    isMuted: channel.isMuted,
                    hasSignal: channel.hasSignal,
                    customName: decodedName
                )
            }
        case 0x11:
            connectionTimeoutTask?.cancel()
            connectionTimeoutTask = nil
            midiChannel = receivedMIDIChannel
            mixerModel = QuMixerModel(boxID: bytes[10])
            storedConnectionState = MixerConnectionState(
                phase: .connected,
                message: "Connected to \(endpoint.host):\(endpoint.port) on MIDI channel \(Int(receivedMIDIChannel) + 1)",
                endpoint: endpoint
            )

            Task {
                try? await requestChannelNames()
                if self.isSignalMonitoringEnabled {
                    try? await self.sendMeterRequest(isEnabled: true)
                }
            }
        case 0x13:
            let payload = Array(bytes[10..<(bytes.count - 1)])
            handleMeterDataPayload(payload)
        default:
            return
        }
    }

    private func startConnectionTimeout(for endpoint: MixerEndpoint) {
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: connectionTimeout)

            guard let self, !Task.isCancelled else {
                return
            }

            guard self.connectionState.phase == .connecting else {
                return
            }

            await self.handleConnectionFailure(
                MixerTransportError.connectionTimedOut(seconds: Int(connectionTimeout.components.seconds)),
                endpoint: endpoint,
                prefix: "Connection timed out"
            )
        }
    }

    private func handleControlChange(status: UInt8, controller: UInt8, value: UInt8) {
        let statusChannel = status & 0x0F
        if let midiChannel, statusChannel != midiChannel {
            return
        }

        switch controller {
        case 0x63:
            nrpnState.channel = value
        case 0x62:
            nrpnState.parameterID = value
        case 0x06:
            nrpnState.dataMSB = value
        case 0x26:
            if let targetChannel = nrpnState.channel,
               let channelID = MixerChannelID(midiChannelCode: targetChannel),
               nrpnState.parameterID == 0x17,
               value == 0x07,
               let dataMSB = nrpnState.dataMSB
            {
                let level = FaderLevel(normalized: Double(dataMSB) / 127)
                storedChannels = storedChannels.map { channel in
                    guard channel.id == channelID else {
                        return channel
                    }
                    return MixerChannelState(
                        id: channel.id,
                        level: level,
                        isMuted: channel.isMuted,
                        hasSignal: channel.hasSignal,
                        customName: channel.customName
                    )
                }
            }
            nrpnState.clear()
        default:
            break
        }
    }

    private func handleNoteMessage(status: UInt8, note: UInt8, velocity: UInt8) {
        let statusType = status & 0xF0
        let statusChannel = status & 0x0F

        guard let midiChannel, statusChannel == midiChannel else {
            return
        }

        guard statusType == 0x90,
              velocity > 0,
              let channelID = MixerChannelID(midiChannelCode: note) else {
            return
        }

        let isMuted = velocity >= 0x40
        storedChannels = storedChannels.map { channel in
            guard channel.id == channelID else {
                return channel
            }

            return MixerChannelState(
                id: channel.id,
                level: channel.level,
                isMuted: isMuted,
                hasSignal: channel.hasSignal,
                customName: channel.customName
            )
        }
    }

    private func handleMeterDataPayload(_ payload: [UInt8]) {
        guard isSignalMonitoringEnabled,
              let signalLevels = QuSignalActivityDecoder.decodeSignalLevels(
                  from7BitPayload: payload,
                  mixerModel: mixerModel
              ) else {
            return
        }

        var resolvedStates: [MixerChannelID: Bool] = [:]
        for channel in storedChannels {
            let decibels = signalLevels[channel.id] ?? QuSignalActivityDecoder.silenceFloor
            resolvedStates[channel.id] = resolvedSignalState(
                currentState: channel.hasSignal,
                decibels: decibels
            )
        }

        pendingSignalStates = resolvedStates
        scheduleSignalPublishIfNeeded()
    }

    private func resolvedSignalState(currentState: Bool, decibels: Double) -> Bool {
        let turnOnThreshold = -60.0
        let turnOffThreshold = -72.0

        if currentState {
            return decibels >= turnOffThreshold
        }

        return decibels >= turnOnThreshold
    }

    private func scheduleSignalPublishIfNeeded() {
        guard signalPublishTask == nil else {
            return
        }

        signalPublishTask = Task { [weak self] in
            guard let self else {
                return
            }

            try? await Task.sleep(for: self.signalPublishInterval)
            guard !Task.isCancelled else {
                return
            }

            self.applyPendingSignalStates()
            self.signalPublishTask = nil
        }
    }

    private func applyPendingSignalStates() {
        guard isSignalMonitoringEnabled else {
            return
        }

        let signalStates = pendingSignalStates
        guard !signalStates.isEmpty else {
            return
        }

        storedChannels = storedChannels.map { channel in
            MixerChannelState(
                id: channel.id,
                level: channel.level,
                isMuted: channel.isMuted,
                hasSignal: signalStates[channel.id] ?? false,
                customName: channel.customName
            )
        }
    }

    private func clearSignalStates() {
        pendingSignalStates.removeAll(keepingCapacity: false)
        signalPublishTask?.cancel()
        signalPublishTask = nil
        storedChannels = storedChannels.map { channel in
            MixerChannelState(
                id: channel.id,
                level: channel.level,
                isMuted: channel.isMuted,
                hasSignal: false,
                customName: channel.customName
            )
        }
    }

    private func disconnectTransport(updateState: Bool, intentional: Bool) async {
        isIntentionalDisconnect = intentional
        activeSenseTask?.cancel()
        activeSenseTask = nil
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        signalPublishTask?.cancel()
        signalPublishTask = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        midiChannel = nil
        mixerModel = nil
        byteBuffer.removeAll(keepingCapacity: false)
        nrpnState.clear()
        pendingSignalStates.removeAll(keepingCapacity: false)
        storedChannels = storedChannels.map { channel in
            MixerChannelState(
                id: channel.id,
                level: channel.level,
                isMuted: false,
                hasSignal: false,
                customName: channel.customName
            )
        }

        if updateState {
            storedConnectionState = MixerConnectionState(
                phase: .disconnected,
                message: "Disconnected",
                endpoint: nil
            )
        }
    }

    private func handleConnectionFailure(
        _ error: Error,
        endpoint: MixerEndpoint?,
        prefix: String
    ) async {
        if isIntentionalDisconnect {
            return
        }

        await disconnectTransport(updateState: false, intentional: true)
        storedConnectionState = MixerConnectionState(
            phase: .error,
            message: formattedErrorMessage(for: error, prefix: prefix),
            endpoint: endpoint
        )
    }

    private func formattedErrorMessage(for error: Error, prefix: String) -> String {
        let rawMessage = error.localizedDescription
        let loweredMessage = rawMessage.lowercased()

        if loweredMessage.contains("connection reset by peer") {
            return "\(prefix): \(rawMessage)\nAnother client may already be connected to the mixer."
        }

        return "\(prefix): \(rawMessage)"
    }

    private static func makeInitialChannels() -> [MixerChannelState] {
        MixerChannelID.selectableChannels.map { channelID in
            MixerChannelState(
                id: channelID,
                level: FaderLevel(normalized: channelID == .mainLr ? 0.72 : 0),
                isMuted: false,
                hasSignal: false,
                customName: nil
            )
        }
    }

    private func sanitizedChannelName(from nameBytes: [UInt8]) -> String? {
        let filteredBytes = nameBytes.filter { byte in
            byte != 0x00 && byte >= 0x20 && byte <= 0x7E
        }

        guard let decodedName = String(bytes: filteredBytes, encoding: .ascii)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !decodedName.isEmpty else {
            return nil
        }

        return decodedName
    }
}

private struct NRPNState {
    var channel: UInt8?
    var parameterID: UInt8?
    var dataMSB: UInt8?

    mutating func clear() {
        channel = nil
        parameterID = nil
        dataMSB = nil
    }
}

private final class ConnectionStartState: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    nonisolated func markResumed() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !resumed else {
            return false
        }

        resumed = true
        return true
    }
}

private enum MixerTransportError: LocalizedError {
    case invalidPort(Int)
    case cancelledBeforeReady
    case notConnected
    case connectionClosed
    case connectionTimedOut(seconds: Int)

    var errorDescription: String? {
        switch self {
        case .invalidPort(let port):
            "Invalid mixer port \(port)"
        case .cancelledBeforeReady:
            "Connection cancelled before ready"
        case .notConnected:
            "Not connected"
        case .connectionClosed:
            "Connection closed by mixer"
        case .connectionTimedOut(let seconds):
            "No response within \(seconds) seconds"
        }
    }
}

private extension FaderLevel {
    func toMIDIValue() -> Int {
        let clampedValue = min(max(normalized, 0), 1)
        return Int((clampedValue * 127).rounded(.towardZero))
    }
}

private enum QuMixerModel {
    case qu16
    case qu24
    case qu32Family

    init?(boxID: UInt8) {
        switch boxID {
        case 1:
            self = .qu16
        case 2:
            self = .qu24
        case 3, 4, 5:
            self = .qu32Family
        default:
            return nil
        }
    }
}

private enum QuSignalActivityDecoder {
    static let silenceFloor = -128.0

    fileprivate static let monoInputBlockSize = 10
    fileprivate static let stereoInputBlockSize = 20
    fileprivate static let monoMixBlockSize = 10
    fileprivate static let stereoMixBlockSize = 20
    fileprivate static let stereoMonitorBlockSize = 78
    private static let monoInputSignalOffsets = [0, 1, 2, 3, 6]
    private static let lrStereoMixSignalOffsets = [5, 15]
    private static let mainMonitorSignalOffsets = [5, 6, 7, 8, 11, 12]

    static func decodeSignalLevels(
        from7BitPayload payload: [UInt8],
        mixerModel: QuMixerModel?
    ) -> [MixerChannelID: Double]? {
        let bytes = unpack7Bitized(payload)
        guard !bytes.isEmpty else {
            return nil
        }

        let meterValues = decodeMeterValues(from: bytes)
        guard let layout = resolveLayout(for: meterValues.count, mixerModel: mixerModel) else {
            return nil
        }

        var result: [MixerChannelID: Double] = [:]

        for channelIndex in 0 ..< 16 {
            let blockStart = channelIndex * monoInputBlockSize
            let blockEnd = blockStart + monoInputBlockSize
            guard blockEnd <= meterValues.count else {
                break
            }

            let channelID = MixerChannelID.selectableChannels[channelIndex]
            result[channelID] = monoInputSignalOffsets
                .compactMap { offset in
                    let meterIndex = blockStart + offset
                    return meterIndex < blockEnd ? meterValues[meterIndex] : nil
                }
                .max() ?? silenceFloor
        }

        let mainLRCandidates =
            mainMonitorSignalOffsets.compactMap { offset -> Double? in
                let meterIndex = layout.monitorBlockStartOffset + offset
                guard meterIndex < meterValues.count else {
                    return nil
                }
                return meterValues[meterIndex]
            } +
            lrStereoMixSignalOffsets.compactMap { offset -> Double? in
                let meterIndex = layout.lrStereoMixBlockStartOffset + offset
                guard meterIndex < meterValues.count else {
                    return nil
                }
                return meterValues[meterIndex]
            }

        result[.mainLr] = mainLRCandidates.max() ?? silenceFloor
        return result
    }

    private static func unpack7Bitized(_ payload: [UInt8]) -> [UInt8] {
        var unpacked: [UInt8] = []
        var index = 0

        while index < payload.count {
            let header = payload[index]
            index += 1

            let remaining = payload.count - index
            let chunkSize = min(7, remaining)
            guard chunkSize > 0 else {
                break
            }

            for bitIndex in 0 ..< chunkSize {
                let lowBits = payload[index + bitIndex] & 0x7F
                let highBit = ((header >> (6 - bitIndex)) & 0x01) << 7
                unpacked.append(lowBits | highBit)
            }

            index += chunkSize
        }

        return unpacked
    }

    private static func decodeMeterValues(from bytes: [UInt8]) -> [Double] {
        var values: [Double] = []
        values.reserveCapacity(bytes.count / 2)

        var index = 0
        while index + 1 < bytes.count {
            let rawValue = UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])
            let signedValue = Int16(bitPattern: rawValue &- 0x8000)
            values.append(Double(signedValue) / 256.0)
            index += 2
        }

        return values
    }

    private static func resolveLayout(for meterCount: Int, mixerModel: QuMixerModel?) -> QuSignalLayout? {
        if let mixerModel {
            let preferredLayout = QuSignalLayout(for: mixerModel)
            if meterCount >= preferredLayout.minimumMeterCount {
                return preferredLayout
            }
        }

        let layouts = [
            QuSignalLayout(for: .qu16),
            QuSignalLayout(for: .qu24),
            QuSignalLayout(for: .qu32Family)
        ]

        return layouts
            .filter { meterCount >= $0.minimumMeterCount }
            .min { abs($0.minimumMeterCount - meterCount) < abs($1.minimumMeterCount - meterCount) }
    }
}

private struct QuSignalLayout {
    let minimumMeterCount: Int
    let lrStereoMixBlockStartOffset: Int
    let monitorBlockStartOffset: Int

    init(for mixerModel: QuMixerModel) {
        switch mixerModel {
        case .qu16:
            lrStereoMixBlockStartOffset = (16 * QuSignalActivityDecoder.monoInputBlockSize) + 80 + (3 * QuSignalActivityDecoder.stereoInputBlockSize) + 20 + (4 * QuSignalActivityDecoder.monoMixBlockSize) + (3 * QuSignalActivityDecoder.stereoMixBlockSize)
            minimumMeterCount = (16 * QuSignalActivityDecoder.monoInputBlockSize) + 80 + (3 * QuSignalActivityDecoder.stereoInputBlockSize) + 20 + (4 * QuSignalActivityDecoder.monoMixBlockSize) + (4 * QuSignalActivityDecoder.stereoMixBlockSize) + QuSignalActivityDecoder.stereoMonitorBlockSize + (4 * 18)
            monitorBlockStartOffset = (16 * QuSignalActivityDecoder.monoInputBlockSize) + 80 + (3 * QuSignalActivityDecoder.stereoInputBlockSize) + 20 + (4 * QuSignalActivityDecoder.monoMixBlockSize) + (4 * QuSignalActivityDecoder.stereoMixBlockSize)
        case .qu24:
            lrStereoMixBlockStartOffset = (24 * QuSignalActivityDecoder.monoInputBlockSize) + (3 * QuSignalActivityDecoder.stereoInputBlockSize) + 180 + (4 * QuSignalActivityDecoder.monoMixBlockSize) + (3 * QuSignalActivityDecoder.stereoMixBlockSize)
            minimumMeterCount = (24 * QuSignalActivityDecoder.monoInputBlockSize) + (3 * QuSignalActivityDecoder.stereoInputBlockSize) + 180 + (4 * QuSignalActivityDecoder.monoMixBlockSize) + (4 * QuSignalActivityDecoder.stereoMixBlockSize) + (2 * QuSignalActivityDecoder.stereoMixBlockSize) + (2 * QuSignalActivityDecoder.stereoMixBlockSize) + QuSignalActivityDecoder.stereoMonitorBlockSize + (4 * 18)
            monitorBlockStartOffset = (24 * QuSignalActivityDecoder.monoInputBlockSize) + (3 * QuSignalActivityDecoder.stereoInputBlockSize) + 180 + (4 * QuSignalActivityDecoder.monoMixBlockSize) + (4 * QuSignalActivityDecoder.stereoMixBlockSize) + (2 * QuSignalActivityDecoder.stereoMixBlockSize) + (2 * QuSignalActivityDecoder.stereoMixBlockSize)
        case .qu32Family:
            lrStereoMixBlockStartOffset = (24 * QuSignalActivityDecoder.monoInputBlockSize) + (3 * QuSignalActivityDecoder.stereoInputBlockSize) + 20 + (8 * QuSignalActivityDecoder.monoInputBlockSize) + (4 * QuSignalActivityDecoder.monoMixBlockSize) + (3 * QuSignalActivityDecoder.stereoMixBlockSize)
            minimumMeterCount = (24 * QuSignalActivityDecoder.monoInputBlockSize) + (3 * QuSignalActivityDecoder.stereoInputBlockSize) + 20 + (8 * QuSignalActivityDecoder.monoInputBlockSize) + (4 * QuSignalActivityDecoder.monoMixBlockSize) + (4 * QuSignalActivityDecoder.stereoMixBlockSize) + (4 * QuSignalActivityDecoder.stereoMixBlockSize) + (2 * QuSignalActivityDecoder.stereoMixBlockSize) + QuSignalActivityDecoder.stereoMonitorBlockSize + (4 * 18)
            monitorBlockStartOffset = (24 * QuSignalActivityDecoder.monoInputBlockSize) + (3 * QuSignalActivityDecoder.stereoInputBlockSize) + 20 + (8 * QuSignalActivityDecoder.monoInputBlockSize) + (4 * QuSignalActivityDecoder.monoMixBlockSize) + (4 * QuSignalActivityDecoder.stereoMixBlockSize) + (4 * QuSignalActivityDecoder.stereoMixBlockSize) + (2 * QuSignalActivityDecoder.stereoMixBlockSize)
        }
    }
}
