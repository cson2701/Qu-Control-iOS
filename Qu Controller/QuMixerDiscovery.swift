//
//  QuMixerDiscovery.swift
//  Qu Controller
//

import Darwin
import Foundation
import Network
import OSLog

struct QuMixerDiscovery {
    private static let logger = Logger(subsystem: "QuController", category: "MixerDiscovery")
    private let port: UInt16
    private let connectTimeout: Duration

    init(
        port: UInt16 = 51_325,
        connectTimeout: Duration = .milliseconds(250)
    ) {
        self.port = port
        self.connectTimeout = connectTimeout
    }

    func discoverMixer(preferredHost: String? = nil) async -> String? {
        _ = preferredHost

        if let discoveredHost = await discoverUsingBroadcast() {
            Self.logger.info(
                "Discovered Qu mixer at \(discoveredHost, privacy: .public) using UDP broadcast"
            )
            return discoveredHost
        }

        Self.logger.info("Qu mixer discovery finished without a response")
        return nil
    }

    private func discoverUsingBroadcast() async -> String? {
        let directedBroadcastAddress = LocalSubnet.active?.directedBroadcastAddress
        return await Task.detached(priority: .userInitiated) {
            Self.performBroadcastDiscovery(directedBroadcastAddress: directedBroadcastAddress)
        }.value
    }

    /// Implements the discovery exchange used by Qu-Pad: broadcast the ASCII
    /// payload `QU Find` to UDP 51320 and accept a null-terminated Qu model name
    /// from the responding mixer's source address.
    nonisolated private static func performBroadcastDiscovery(
        directedBroadcastAddress: UInt32?
    ) -> String? {
        let discoveryPort: UInt16 = 51_320
        let discoveryRequest = Data("QU Find".utf8)
        let socketDescriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketDescriptor >= 0 else {
            Self.logger.error("Could not create Qu discovery socket: errno \(errno)")
            return nil
        }
        defer { close(socketDescriptor) }

        var reuseAddress: Int32 = 1
        guard setsockopt(
            socketDescriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuseAddress,
            socklen_t(MemoryLayout.size(ofValue: reuseAddress))
        ) == 0 else {
            Self.logger.error("Could not configure Qu discovery socket reuse: errno \(errno)")
            return nil
        }

        var broadcastEnabled: Int32 = 1
        guard setsockopt(
            socketDescriptor,
            SOL_SOCKET,
            SO_BROADCAST,
            &broadcastEnabled,
            socklen_t(MemoryLayout.size(ofValue: broadcastEnabled))
        ) == 0 else {
            Self.logger.error("Could not enable Qu discovery broadcasts: errno \(errno)")
            return nil
        }

        // Qu mixers send discovery replies to UDP 51320. Binding explicitly is
        // required; otherwise the request uses an ephemeral source port and the
        // mixer response is not delivered to this socket.
        var localAddress = sockaddr_in()
        localAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        localAddress.sin_family = sa_family_t(AF_INET)
        localAddress.sin_port = discoveryPort.bigEndian
        localAddress.sin_addr = in_addr(s_addr: INADDR_ANY)

        let didBind = withUnsafePointer(to: &localAddress) { localAddressPointer in
            localAddressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(
                    socketDescriptor,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard didBind == 0 else {
            Self.logger.error("Could not bind Qu discovery socket to UDP 51320: errno \(errno)")
            return nil
        }

        var didSendRequest = false
        var destinationAddresses = [INADDR_BROADCAST]
        if let directedBroadcastAddress,
           !destinationAddresses.contains(directedBroadcastAddress) {
            destinationAddresses.append(directedBroadcastAddress)
        }

        for destinationAddress in destinationAddresses {
            var destination = sockaddr_in()
            destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            destination.sin_family = sa_family_t(AF_INET)
            destination.sin_port = discoveryPort.bigEndian
            destination.sin_addr = in_addr(s_addr: destinationAddress)

            for _ in 0 ..< 2 {
                let sentByteCount = discoveryRequest.withUnsafeBytes { requestBytes in
                    withUnsafePointer(to: &destination) { destinationPointer in
                        destinationPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                            sendto(
                                socketDescriptor,
                                requestBytes.baseAddress,
                                requestBytes.count,
                                0,
                                socketAddress,
                                socklen_t(MemoryLayout<sockaddr_in>.size)
                            )
                        }
                    }
                }
                didSendRequest = didSendRequest || sentByteCount == discoveryRequest.count
            }
        }

        guard didSendRequest else {
            Self.logger.error("Could not send Qu discovery broadcast: errno \(errno)")
            return nil
        }

        let deadline = Date().addingTimeInterval(1)
        while true {
            let remainingMilliseconds = Int(deadline.timeIntervalSinceNow * 1_000)
            guard remainingMilliseconds > 0 else {
                Self.logger.info("Qu discovery broadcast timed out without a response")
                return nil
            }

            var pollDescriptor = pollfd(
                fd: socketDescriptor,
                events: Int16(POLLIN),
                revents: 0
            )
            guard poll(&pollDescriptor, 1, Int32(remainingMilliseconds)) > 0 else {
                Self.logger.info("Qu discovery broadcast timed out while waiting for a response")
                return nil
            }

            var source = sockaddr_in()
            var sourceLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            var response = [UInt8](repeating: 0, count: 64)
            let responseCapacity = response.count
            let receivedByteCount = response.withUnsafeMutableBytes { responseBytes in
                withUnsafeMutablePointer(to: &source) { sourcePointer in
                    sourcePointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                        recvfrom(
                            socketDescriptor,
                            responseBytes.baseAddress,
                            responseCapacity,
                            0,
                            socketAddress,
                            &sourceLength
                        )
                    }
                }
            }

            guard receivedByteCount > 1,
                  source.sin_family == sa_family_t(AF_INET),
                  UInt16(bigEndian: source.sin_port) == discoveryPort else {
                continue
            }

            let payload = response.prefix(Int(receivedByteCount))
            let modelBytes = payload.last == 0 ? payload.dropLast() : payload[...]
            guard let model = String(bytes: modelBytes, encoding: .ascii),
                  model.hasPrefix("Qu-") else {
                continue
            }

            var sourceAddress = source.sin_addr
            var addressBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            let convertedAddress = addressBuffer.withUnsafeMutableBufferPointer { buffer in
                inet_ntop(
                    AF_INET,
                    &sourceAddress,
                    buffer.baseAddress,
                    socklen_t(buffer.count)
                )
            }
            guard convertedAddress != nil else {
                continue
            }

            return String(cString: addressBuffer)
        }
    }

    private func probe(host: String) async -> Bool {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            return false
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: endpointPort,
            using: NWParameters.tcp
        )

        let timeoutTask = Task {
            try? await Task.sleep(for: connectTimeout)
            connection.cancel()
        }

        defer {
            timeoutTask.cancel()
            connection.cancel()
        }

        do {
            try await awaitReady(connection)
            try await sendSystemStateRequest(on: connection)
            return try await awaitValidationResponse(on: connection)
        } catch {
            return false
        }
    }

    private func awaitReady(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let didResume = LockedFlag()

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if didResume.setIfNeeded() {
                        continuation.resume(returning: ())
                    }
                case .failed(let error):
                    if didResume.setIfNeeded() {
                        continuation.resume(throwing: error)
                    }
                case .cancelled:
                    if didResume.setIfNeeded() {
                        continuation.resume(throwing: DiscoveryError.cancelled)
                    }
                default:
                    break
                }
            }

            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    private func sendSystemStateRequest(on connection: NWConnection) async throws {
        let bytes: [UInt8] = [0xF0, 0x00, 0x00, 0x1A, 0x50, 0x11, 0x01, 0x00, 0x7F, 0x10, 0x01, 0xF7]
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

    private func awaitValidationResponse(on connection: NWConnection) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            let didResume = LockedFlag()
            var buffer = Data()

            func receiveNext() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                    if let error {
                        if didResume.setIfNeeded() {
                            continuation.resume(throwing: error)
                        }
                        return
                    }

                    if let data, !data.isEmpty {
                        buffer.append(data)
                        if isValidQuHandshakeResponse(buffer) {
                            if didResume.setIfNeeded() {
                                continuation.resume(returning: true)
                            }
                            return
                        }
                    }

                    if isComplete {
                        if didResume.setIfNeeded() {
                            continuation.resume(returning: false)
                        }
                        return
                    }

                    receiveNext()
                }
            }

            receiveNext()
        }
    }

    private func isValidQuHandshakeResponse(_ data: Data) -> Bool {
        let bytes = Array(data)
        guard bytes.count >= 10 else {
            return false
        }

        for index in 0 ... (bytes.count - 10) {
            guard bytes[index] == 0xF0,
                  bytes[index + 1] == 0x00,
                  bytes[index + 2] == 0x00,
                  bytes[index + 3] == 0x1A,
                  bytes[index + 4] == 0x50,
                  bytes[index + 5] == 0x11 else {
                continue
            }

            return (bytes[index + 9] & 0x7F) == 0x11
        }

        return false
    }
}

private struct LocalSubnet {
    static let discoveryNetmaskValue: UInt32 = 0xFF_FF_FF_00
    let address: UInt32
    let netmask: UInt32

    var directedBroadcastAddress: UInt32 {
        ((address & netmask) | ~netmask).bigEndian
    }

    static var active: LocalSubnet? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let interfaces else {
            return nil
        }

        defer {
            freeifaddrs(interfaces)
        }

        var candidates: [(priority: Int, subnet: LocalSubnet)] = []
        var pointer = interfaces

        while true {
            let interface = pointer.pointee

            guard let addressPointer = interface.ifa_addr,
                  addressPointer.pointee.sa_family == UInt8(AF_INET),
                  let netmaskPointer = interface.ifa_netmask else {
                if let next = interface.ifa_next {
                    pointer = next
                    continue
                }
                break
            }

            let flags = Int32(interface.ifa_flags)
            let isUsable =
                (flags & IFF_UP) != 0 &&
                (flags & IFF_RUNNING) != 0 &&
                (flags & IFF_LOOPBACK) == 0

            guard isUsable else {
                if let next = interface.ifa_next {
                    pointer = next
                    continue
                }
                break
            }

            let name = String(cString: interface.ifa_name)
            let address = addressPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                $0.pointee.sin_addr.s_addr.bigEndian
            }
            let netmask = netmaskPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                $0.pointee.sin_addr.s_addr.bigEndian
            }

            guard netmask != 0 else {
                if let next = interface.ifa_next {
                    pointer = next
                    continue
                }
                break
            }

            let priority = interfacePriority(name: name, address: address)
            candidates.append((priority, LocalSubnet(address: address, netmask: netmask)))

            if let next = interface.ifa_next {
                pointer = next
            } else {
                break
            }
        }

        return candidates.sorted(by: { $0.priority < $1.priority }).first?.subnet
    }

    func hostAddresses(maximumCount: Int, preferredHostAddress: UInt32) -> [String] {
        let scanNetmask = Self.discoveryNetmaskValue
        let hostMask = ~scanNetmask
        let usableHostCount = hostMask > 1 ? Int(hostMask - 1) : 0

        guard usableHostCount > 0 else {
            return []
        }

        let networkAddress = address & scanNetmask
        let broadcastAddress = networkAddress | hostMask
        let limit = min(usableHostCount, maximumCount)

        var hosts: [UInt32] = []
        hosts.reserveCapacity(limit)

        for offset in 1 ..< Int(hostMask) {
            let candidate = networkAddress &+ UInt32(offset)
            guard candidate != address, candidate != broadcastAddress else {
                continue
            }

            hosts.append(candidate)
            if hosts.count == limit {
                break
            }
        }

        let localAddress = preferredHostAddress
        hosts.sort {
            abs(Int64($0) - Int64(localAddress)) < abs(Int64($1) - Int64(localAddress))
        }

        return hosts.map(ipv4String)
    }

    var ipv4Address: String {
        ipv4String(address)
    }

    var subnetDescription: String {
        "\(ipv4String(address & discoveryNetmask))/\(discoveryPrefixLength)"
    }

    var thirdOctet: Int {
        Int((address >> 8) & 0xFF)
    }

    var fourthOctet: UInt32 {
        address & 0xFF
    }

    var isPrivate192168: Bool {
        ((address >> 24) & 0xFF) == 192 && ((address >> 16) & 0xFF) == 168
    }

    var discoverySubnet: LocalSubnet {
        LocalSubnet(address: address, netmask: Self.discoveryNetmaskValue)
    }

    private var discoveryNetmask: UInt32 {
        Self.discoveryNetmaskValue
    }

    private var discoveryPrefixLength: Int {
        discoveryNetmask.nonzeroBitCount
    }

    private static func interfacePriority(name: String, address: UInt32) -> Int {
        if isPrivateRFC1918(address) {
            if name.hasPrefix("en") {
                return 0
            }
            if name.hasPrefix("bridge") {
                return 1
            }
            if name.hasPrefix("pdp_ip") {
                return 2
            }
            return 3
        }

        if isLinkLocal(address) {
            if name.hasPrefix("en") {
                return 10
            }
            if name.hasPrefix("bridge") {
                return 11
            }
            if name.hasPrefix("pdp_ip") {
                return 12
            }
            return 13
        }

        if name.hasPrefix("en") {
            return 4
        }
        if name.hasPrefix("bridge") {
            return 5
        }
        if name.hasPrefix("pdp_ip") {
            return 6
        }
        return 7
    }

    private static func isPrivateRFC1918(_ address: UInt32) -> Bool {
        let octet1 = (address >> 24) & 0xFF
        let octet2 = (address >> 16) & 0xFF

        if octet1 == 10 {
            return true
        }

        if octet1 == 172, (16 ... 31).contains(Int(octet2)) {
            return true
        }

        return octet1 == 192 && octet2 == 168
    }

    private static func isLinkLocal(_ address: UInt32) -> Bool {
        ((address >> 24) & 0xFF) == 169 && ((address >> 16) & 0xFF) == 254
    }

    static func ipv4Address(octet1: UInt32, octet2: UInt32, octet3: UInt32, octet4: UInt32) -> UInt32 {
        (octet1 << 24) | (octet2 << 16) | (octet3 << 8) | octet4
    }

    private func ipv4String(_ address: UInt32) -> String {
        [
            String((address >> 24) & 0xFF),
            String((address >> 16) & 0xFF),
            String((address >> 8) & 0xFF),
            String(address & 0xFF)
        ].joined(separator: ".")
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var isSet = false

    nonisolated func setIfNeeded() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !isSet else {
            return false
        }

        isSet = true
        return true
    }
}

private enum DiscoveryError: Error {
    case cancelled
}
