import Combine
import Foundation
import Network

@MainActor
final class QuRelayMixerController: MixerController {
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

    private let connectionQueue = DispatchQueue(label: "com.scrapps.qucontroller.relay")
    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var relayEndpoint: MixerEndpoint?
    private var isIntentionalDisconnect = false

    func connect(to endpoint: MixerEndpoint) async {
        await disconnectTransport(updateState: false, intentional: false)
        isIntentionalDisconnect = false
        relayEndpoint = endpoint
        storedConnectionState = MixerConnectionState(
            phase: .connecting,
            message: "Connecting to relay at \(endpoint.host):\(endpoint.port)",
            endpoint: endpoint
        )

        do {
            let connection = try makeConnection(for: endpoint)
            self.connection = connection
            startReceiving(on: connection, endpoint: endpoint)
        } catch {
            await handleConnectionFailure(error, endpoint: endpoint, prefix: "Relay connection failed")
        }
    }

    func disconnect() {
        Task {
            await disconnectTransport(updateState: true, intentional: true)
        }
    }

    func shutdownMixer() async {
        do {
            try await send(.shutdownMixer())
        } catch {
            await handleConnectionFailure(error, endpoint: relayEndpoint, prefix: "Shutdown failed")
        }
    }

    func setLevel(for channelID: MixerChannelID, level: FaderLevel) {
        Task {
            do {
                try await send(.setLevel(channel: channelID, level: level.normalized))
            } catch {
                await handleConnectionFailure(error, endpoint: relayEndpoint, prefix: "Send failed")
            }
        }
    }

    func setMute(for channelID: MixerChannelID, isMuted: Bool) {
        Task {
            do {
                try await send(.setMute(channel: channelID, isMuted: isMuted))
            } catch {
                await handleConnectionFailure(error, endpoint: relayEndpoint, prefix: "Send failed")
            }
        }
    }

    func setSignalMonitoringEnabled(_ isEnabled: Bool) {
        // The current Mac relay protocol does not support a signal-monitoring command.
        // Relay snapshots may still include signal state when the host app has it enabled.
        _ = isEnabled
    }

    private func makeConnection(for endpoint: MixerEndpoint) throws -> NWConnection {
        guard let port = NWEndpoint.Port(rawValue: UInt16(endpoint.port)) else {
            throw RelayTransportError.invalidPort(endpoint.port)
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(endpoint.host),
            port: port,
            using: .tcp
        )

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            Task { @MainActor [weak self, weak connection] in
                guard let self, let connection, self.connection === connection else { return }

                switch state {
                case .ready:
                    if self.storedConnectionState.phase == .connecting {
                        self.storedConnectionState = MixerConnectionState(
                            phase: .connecting,
                            message: "Connected to relay at \(endpoint.host):\(endpoint.port). Waiting for mixer state.",
                            endpoint: endpoint
                        )
                    }
                case .failed(let error):
                    await self.handleConnectionFailure(error, endpoint: endpoint, prefix: "Relay connection failed")
                case .cancelled:
                    if !self.isIntentionalDisconnect {
                        await self.handleConnectionFailure(
                            RelayTransportError.connectionClosed,
                            endpoint: endpoint,
                            prefix: "Relay connection failed"
                        )
                    }
                default:
                    break
                }
            }
        }

        connection.start(queue: connectionQueue)
        return connection
    }

    private func startReceiving(on connection: NWConnection, endpoint: MixerEndpoint) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak connection] data, _, isComplete, error in
            Task { @MainActor [weak self, weak connection] in
                guard let self, let connection, self.connection === connection else { return }

                if let error {
                    await self.handleConnectionFailure(error, endpoint: endpoint, prefix: "Relay connection lost")
                    return
                }

                if let data, !data.isEmpty {
                    self.receiveBuffer.append(data)
                    self.processBufferedMessages(endpoint: endpoint)
                }

                if isComplete {
                    await self.handleConnectionFailure(
                        RelayTransportError.connectionClosed,
                        endpoint: endpoint,
                        prefix: "Relay connection lost"
                    )
                    return
                }

                self.startReceiving(on: connection, endpoint: endpoint)
            }
        }
    }

    private func processBufferedMessages(endpoint: MixerEndpoint) {
        while let newlineIndex = receiveBuffer.firstIndex(of: 0x0A) {
            let line = Data(receiveBuffer[..<newlineIndex])
            receiveBuffer.removeSubrange(...newlineIndex)

            guard !line.isEmpty else {
                continue
            }

            do {
                let message = try JSONDecoder().decode(MixerRelayServerMessage.self, from: line)
                handleServerMessage(message, endpoint: endpoint)
            } catch {
                storedConnectionState = MixerConnectionState(
                    phase: .error,
                    message: "Relay protocol error: \(error.localizedDescription)",
                    endpoint: endpoint
                )
            }
        }
    }

    private func handleServerMessage(_ message: MixerRelayServerMessage, endpoint: MixerEndpoint) {
        switch message.type {
        case "snapshot":
            guard let connectionSnapshot = message.connection,
                  let channelSnapshots = message.channels else {
                storedConnectionState = MixerConnectionState(
                    phase: .error,
                    message: "Relay protocol error: Snapshot missing connection or channels",
                    endpoint: endpoint
                )
                return
            }

            storedChannels = channelSnapshots.map(\.channelState)
            storedConnectionState = MixerConnectionState(
                phase: resolvedPhase(from: connectionSnapshot.phase),
                message: formattedRelayMessage(from: connectionSnapshot, endpoint: endpoint),
                endpoint: endpoint
            )
        case "error":
            storedConnectionState = MixerConnectionState(
                phase: .error,
                message: message.message ?? "Relay reported an unknown error",
                endpoint: endpoint
            )
        default:
            storedConnectionState = MixerConnectionState(
                phase: .error,
                message: "Relay protocol error: Unsupported message type \(message.type)",
                endpoint: endpoint
            )
        }
    }

    private func resolvedPhase(from rawPhase: String) -> MixerConnectionPhase {
        switch rawPhase {
        case "connected":
            .connected
        case "connecting":
            .connecting
        case "error":
            .error
        case "disconnected":
            .disconnected
        default:
            .error
        }
    }

    private func formattedRelayMessage(
        from snapshot: MixerRelayConnectionSnapshot,
        endpoint: MixerEndpoint
    ) -> String {
        let snapshotMessage = snapshot.message
        let remoteEndpointSuffix: String
        if let remoteEndpoint = snapshot.endpoint,
           !snapshotMessage.contains("\(remoteEndpoint.host):\(remoteEndpoint.port)") {
            remoteEndpointSuffix = " Mixer endpoint: \(remoteEndpoint.host):\(remoteEndpoint.port)."
        } else {
            remoteEndpointSuffix = ""
        }

        return "Relay \(endpoint.host):\(endpoint.port). \(snapshotMessage)\(remoteEndpointSuffix)"
    }

    private func send(_ command: MixerRelayClientCommand) async throws {
        guard let connection else {
            throw RelayTransportError.notConnected
        }

        var data = try JSONEncoder().encode(command)
        data.append(0x0A)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }

    private func disconnectTransport(updateState: Bool, intentional: Bool) async {
        isIntentionalDisconnect = intentional
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        relayEndpoint = nil
        receiveBuffer.removeAll(keepingCapacity: false)
        storedChannels = QuNetworkMixerController.makeInitialChannels()

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
            message: "\(prefix): \(error.localizedDescription)",
            endpoint: endpoint
        )
    }
}

private enum RelayTransportError: LocalizedError {
    case invalidPort(Int)
    case notConnected
    case connectionClosed

    var errorDescription: String? {
        switch self {
        case .invalidPort(let port):
            "Invalid relay port \(port)"
        case .notConnected:
            "Not connected to relay"
        case .connectionClosed:
            "Connection closed by relay"
        }
    }
}
