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
    private static let privateClassBPrefixOctet1: UInt32 = 192
    private static let privateClassBPrefixOctet2: UInt32 = 168
    private let port: UInt16
    private let connectTimeout: Duration
    private let concurrencyLimit: Int
    private let maximumHostsToScan: Int

    init(
        port: UInt16 = 51_325,
        connectTimeout: Duration = .milliseconds(250),
        concurrencyLimit: Int = 32,
        maximumHostsToScan: Int = 4096
    ) {
        self.port = port
        self.connectTimeout = connectTimeout
        self.concurrencyLimit = concurrencyLimit
        self.maximumHostsToScan = maximumHostsToScan
    }

    func discoverMixer(preferredHost: String? = nil) async -> String? {
        guard let subnet = LocalSubnet.active,
              let hosts = prioritizedHosts(
                from: subnet,
                preferredHost: preferredHost,
                maximumCount: maximumHostsToScan
              ),
              !hosts.isEmpty else {
            return nil
        }

        Self.logger.info(
            "Starting mixer discovery from local address \(subnet.ipv4Address, privacy: .public) on subnet \(subnet.subnetDescription, privacy: .public) with \(hosts.count) hosts"
        )

        let scanState = ScanState(hosts: hosts)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< min(concurrencyLimit, hosts.count) {
                group.addTask {
                    await scanHosts(using: scanState)
                }
            }
        }

        return await scanState.foundHost
    }

    func isMixerReachable(at host: String) async -> Bool {
        await probe(host: host)
    }

    private func prioritizedHosts(
        from subnet: LocalSubnet,
        preferredHost: String?,
        maximumCount: Int
    ) -> [String]? {
        let scanSubnets = candidateSubnets(for: subnet)
        var hosts: [String] = []
        hosts.reserveCapacity(maximumCount)

        if let preferredHost, !preferredHost.isEmpty {
            hosts.append(preferredHost)
        }

        for scanSubnet in scanSubnets {
            let remainingCapacity = maximumCount - hosts.count
            guard remainingCapacity > 0 else {
                break
            }

            let subnetHosts = scanSubnet.hostAddresses(
                maximumCount: remainingCapacity,
                preferredHostAddress: subnet.address
            )
            for host in subnetHosts where !hosts.contains(host) {
                hosts.append(host)
            }
        }

        return hosts.isEmpty ? nil : hosts
    }

    private func candidateSubnets(for subnet: LocalSubnet) -> [LocalSubnet] {
        guard subnet.isPrivate192168 else {
            return [subnet.discoverySubnet]
        }

        let thirdOctets = prioritizedThirdOctets(near: subnet.thirdOctet)
        return thirdOctets.map { thirdOctet in
            LocalSubnet(
                address: LocalSubnet.ipv4Address(
                    octet1: Self.privateClassBPrefixOctet1,
                    octet2: Self.privateClassBPrefixOctet2,
                    octet3: UInt32(thirdOctet),
                    octet4: subnet.fourthOctet
                ),
                netmask: LocalSubnet.discoveryNetmaskValue
            )
        }
    }

    private func prioritizedThirdOctets(near localThirdOctet: Int) -> [Int] {
        (0 ... 255).sorted { lhs, rhs in
            abs(lhs - localThirdOctet) < abs(rhs - localThirdOctet)
        }
    }

    private func scanHosts(using scanState: ScanState) async {
        while !Task.isCancelled {
            guard let host = await scanState.nextHost() else {
                return
            }

            Self.logger.info("Scanning mixer candidate \(host, privacy: .public)")

            if await probe(host: host) {
                await scanState.setFoundHost(host)
                return
            }
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

private actor ScanState {
    private var remainingHosts: ArraySlice<String>
    private(set) var foundHost: String?

    init(hosts: [String]) {
        remainingHosts = ArraySlice(hosts)
    }

    func nextHost() -> String? {
        guard foundHost == nil, let host = remainingHosts.popFirst() else {
            return nil
        }

        return host
    }

    func setFoundHost(_ host: String) {
        guard foundHost == nil else {
            return
        }

        foundHost = host
        remainingHosts = []
    }
}

private struct LocalSubnet {
    static let discoveryNetmaskValue: UInt32 = 0xFF_FF_FF_00
    let address: UInt32
    let netmask: UInt32

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
