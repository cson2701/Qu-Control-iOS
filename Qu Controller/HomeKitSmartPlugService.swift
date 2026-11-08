import Combine
import Foundation
import HomeKit

struct HomeKitSmartPlug: Identifiable, Equatable {
    let homeIdentifier: UUID
    let accessoryIdentifier: UUID
    let serviceIdentifier: UUID
    let name: String
    let location: String

    var id: String {
        [
            homeIdentifier.uuidString,
            accessoryIdentifier.uuidString,
            serviceIdentifier.uuidString
        ].joined(separator: ":")
    }
}

enum HomeKitSmartPlugError: LocalizedError {
    case accessDenied
    case plugUnavailable
    case powerCharacteristicUnavailable
    case powerStateUnavailable
    case powerUpdateInProgress

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            "Qu Controller does not have access to Apple Home. Allow Home access in Settings and try again."
        case .plugUnavailable:
            "The selected HomeKit smart plug is unavailable or has been removed."
        case .powerCharacteristicUnavailable:
            "The selected HomeKit accessory no longer provides a writable power control."
        case .powerStateUnavailable:
            "The selected HomeKit smart plug did not report its current power state."
        case .powerUpdateInProgress:
            "The smart plug is already processing another power change."
        }
    }
}

@MainActor
final class HomeKitSmartPlugService: NSObject, ObservableObject, PostShutdownPowerControlling {
    @Published private(set) var availablePlugs: [HomeKitSmartPlug] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isAutomaticPowerOffEnabled: Bool
    @Published private(set) var delaySeconds: Int
    @Published private(set) var selectedPlugID: String?
    @Published private(set) var selectedPlugName: String?
    @Published private(set) var selectedPlugIsOn: Bool?
    @Published private(set) var isUpdatingPlugPower = false

    private let userDefaults: UserDefaults
    private var homeManager: HMHomeManager?
    private var hasLoadedHomes = false
    private var loadContinuations: [CheckedContinuation<Void, Never>] = []
    private var monitoredAccessory: HMAccessory?
    private var monitoredPowerCharacteristic: HMCharacteristic?

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        isAutomaticPowerOffEnabled = userDefaults.bool(forKey: AppSettingsKey.homeKitPowerOffEnabled)
        delaySeconds = Self.loadDelay(from: userDefaults)
        selectedPlugID = Self.loadSelectedPlugID(from: userDefaults)
        selectedPlugName = userDefaults.string(forKey: AppSettingsKey.homeKitPlugName)
        selectedPlugIsOn = nil
        super.init()
    }

    var hasSelectedPlug: Bool {
        selectedPlugID != nil
    }

    var authorizationDescription: String {
        guard let homeManager else {
            return "Home access has not been requested."
        }

        let status = homeManager.authorizationStatus
        if status.contains(.authorized) {
            return "Apple Home access is allowed."
        }
        if status.contains(.restricted) {
            return "Apple Home access is restricted."
        }
        if status.contains(.determined) {
            return "Apple Home access is not allowed."
        }
        return "Waiting for Apple Home permission."
    }

    func setAutomaticPowerOffEnabled(_ isEnabled: Bool) {
        isAutomaticPowerOffEnabled = isEnabled
        userDefaults.set(isEnabled, forKey: AppSettingsKey.homeKitPowerOffEnabled)
        if isEnabled {
            loadPlugs()
        }
    }

    func setDelaySeconds(_ seconds: Int) {
        let clampedSeconds = min(max(seconds, 0), 5)
        delaySeconds = clampedSeconds
        userDefaults.set(clampedSeconds, forKey: AppSettingsKey.homeKitShutdownDelaySeconds)
    }

    func selectPlug(withID id: String?) {
        guard let id,
              let plug = availablePlugs.first(where: { $0.id == id }) else {
            clearSelectedPlug()
            return
        }

        selectedPlugID = plug.id
        selectedPlugName = plug.name
        userDefaults.set(plug.homeIdentifier.uuidString, forKey: AppSettingsKey.homeKitHomeIdentifier)
        userDefaults.set(plug.accessoryIdentifier.uuidString, forKey: AppSettingsKey.homeKitAccessoryIdentifier)
        userDefaults.set(plug.serviceIdentifier.uuidString, forKey: AppSettingsKey.homeKitServiceIdentifier)
        userDefaults.set(plug.name, forKey: AppSettingsKey.homeKitPlugName)
        errorMessage = nil
        Task {
            await configureSelectedPlugMonitoring()
            _ = await refreshSelectedPlugPowerState()
        }
    }

    func loadPlugs() {
        Task {
            isLoading = true
            await ensureHomesLoaded()
            refreshAvailablePlugs()
            await configureSelectedPlugMonitoring()
            _ = await refreshSelectedPlugPowerState()
            isLoading = false
        }
    }

    /// Re-establishes HomeKit event delivery and performs one read after the
    /// app becomes active. Ongoing updates are notification-driven.
    func applicationDidBecomeActive() {
        guard hasSelectedPlug else { return }

        Task {
            await ensureHomesLoaded()
            await configureSelectedPlugMonitoring()
            _ = await refreshSelectedPlugPowerState()
        }
    }

    func setSelectedPlugPower(_ isOn: Bool) {
        Task {
            do {
                try await updateSelectedPlugPower(isOn)
            } catch {
                // The observable error message is set by updateSelectedPlugPower.
            }
        }
    }

    func updateSelectedPlugPower(_ isOn: Bool) async throws {
        guard !isUpdatingPlugPower else {
            throw HomeKitSmartPlugError.powerUpdateInProgress
        }

        isUpdatingPlugPower = true
        defer { isUpdatingPlugPower = false }

        do {
            await ensureHomesLoaded()
            let characteristic = try selectedPowerCharacteristic()
            try await writePowerState(isOn, to: characteristic)
            selectedPlugIsOn = isOn
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func turnOffSelectedPlug() async throws {
        await ensureHomesLoaded()
        let characteristic = try selectedPowerCharacteristic()
        try await writePowerState(false, to: characteristic)
        selectedPlugIsOn = false
    }

    private func ensureHomesLoaded() async {
        guard !hasLoadedHomes else { return }

        await withCheckedContinuation { continuation in
            loadContinuations.append(continuation)
            guard homeManager == nil else { return }

            let manager = HMHomeManager()
            manager.delegate = self
            homeManager = manager
        }
    }

    private func refreshAvailablePlugs() {
        guard let homeManager else { return }

        availablePlugs = homeManager.homes.flatMap { home in
            home.accessories.flatMap { accessory in
                accessory.services.compactMap { service in
                    guard Self.isPowerService(service),
                          Self.writablePowerCharacteristic(in: service) != nil else {
                        return nil
                    }

                    let serviceName = service.name == accessory.name
                        ? accessory.name
                        : "\(accessory.name) — \(service.name)"
                    return HomeKitSmartPlug(
                        homeIdentifier: home.uniqueIdentifier,
                        accessoryIdentifier: accessory.uniqueIdentifier,
                        serviceIdentifier: service.uniqueIdentifier,
                        name: serviceName,
                        location: [home.name, accessory.room?.name].compactMap { $0 }.joined(separator: " · ")
                    )
                }
            }
        }
        .sorted { lhs, rhs in
            lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        if let selectedPlugID,
           let selectedPlug = availablePlugs.first(where: { $0.id == selectedPlugID }) {
            selectedPlugName = selectedPlug.name
            userDefaults.set(selectedPlug.name, forKey: AppSettingsKey.homeKitPlugName)
            errorMessage = nil
        } else if hasSelectedPlug {
            errorMessage = HomeKitSmartPlugError.plugUnavailable.localizedDescription
        } else if !homeManager.authorizationStatus.contains(.authorized) {
            errorMessage = HomeKitSmartPlugError.accessDenied.localizedDescription
        } else {
            errorMessage = nil
        }
    }

    func refreshSelectedPlugPowerState() async -> Bool? {
        guard hasSelectedPlug else {
            selectedPlugIsOn = nil
            return nil
        }

        do {
            await ensureHomesLoaded()
            let characteristic = try selectedPowerCharacteristic()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                characteristic.readValue { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }

            guard let powerState = Self.powerState(from: characteristic.value) else {
                throw HomeKitSmartPlugError.powerStateUnavailable
            }
            selectedPlugIsOn = powerState
            errorMessage = nil
            return powerState
        } catch {
            selectedPlugIsOn = nil
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func selectedPowerCharacteristic() throws -> HMCharacteristic {
        try selectedPowerTarget().characteristic
    }

    private func selectedPowerTarget() throws -> (accessory: HMAccessory, characteristic: HMCharacteristic) {
        guard let homeManager,
              homeManager.authorizationStatus.contains(.authorized) else {
            throw HomeKitSmartPlugError.accessDenied
        }
        guard let identifiers = selectedIdentifiers(),
              let home = homeManager.homes.first(where: { $0.uniqueIdentifier == identifiers.home }),
              let accessory = home.accessories.first(where: { $0.uniqueIdentifier == identifiers.accessory }),
              let service = accessory.services.first(where: { $0.uniqueIdentifier == identifiers.service }) else {
            throw HomeKitSmartPlugError.plugUnavailable
        }
        guard let characteristic = Self.writablePowerCharacteristic(in: service) else {
            throw HomeKitSmartPlugError.powerCharacteristicUnavailable
        }
        return (accessory, characteristic)
    }

    private func configureSelectedPlugMonitoring() async {
        guard hasSelectedPlug else {
            await stopMonitoringSelectedPlug()
            return
        }

        do {
            let selectedID = selectedPlugID
            let target = try selectedPowerTarget()

            if monitoredPowerCharacteristic === target.characteristic,
               monitoredAccessory === target.accessory,
               target.characteristic.isNotificationEnabled {
                target.accessory.delegate = self
                return
            }

            await stopMonitoringSelectedPlug()
            target.accessory.delegate = self
            try await setNotificationsEnabled(true, for: target.characteristic)

            guard selectedPlugID == selectedID else {
                try? await setNotificationsEnabled(false, for: target.characteristic)
                return
            }

            monitoredAccessory = target.accessory
            monitoredPowerCharacteristic = target.characteristic
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func stopMonitoringSelectedPlug() async {
        let characteristic = monitoredPowerCharacteristic
        let accessory = monitoredAccessory
        monitoredPowerCharacteristic = nil
        monitoredAccessory = nil

        if let characteristic, characteristic.isNotificationEnabled {
            try? await setNotificationsEnabled(false, for: characteristic)
        }
        if accessory?.delegate === self {
            accessory?.delegate = nil
        }
    }

    private func setNotificationsEnabled(_ isEnabled: Bool, for characteristic: HMCharacteristic) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            characteristic.enableNotification(isEnabled) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func writePowerState(_ isOn: Bool, to characteristic: HMCharacteristic) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            characteristic.writeValue(isOn) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func clearSelectedPlug() {
        Task {
            await stopMonitoringSelectedPlug()
        }
        selectedPlugID = nil
        selectedPlugName = nil
        selectedPlugIsOn = nil
        userDefaults.removeObject(forKey: AppSettingsKey.homeKitHomeIdentifier)
        userDefaults.removeObject(forKey: AppSettingsKey.homeKitAccessoryIdentifier)
        userDefaults.removeObject(forKey: AppSettingsKey.homeKitServiceIdentifier)
        userDefaults.removeObject(forKey: AppSettingsKey.homeKitPlugName)
    }

    private func selectedIdentifiers() -> (home: UUID, accessory: UUID, service: UUID)? {
        guard let homeString = userDefaults.string(forKey: AppSettingsKey.homeKitHomeIdentifier),
              let accessoryString = userDefaults.string(forKey: AppSettingsKey.homeKitAccessoryIdentifier),
              let serviceString = userDefaults.string(forKey: AppSettingsKey.homeKitServiceIdentifier),
              let home = UUID(uuidString: homeString),
              let accessory = UUID(uuidString: accessoryString),
              let service = UUID(uuidString: serviceString) else {
            return nil
        }
        return (home, accessory, service)
    }

    private static func loadDelay(from userDefaults: UserDefaults) -> Int {
        guard userDefaults.object(forKey: AppSettingsKey.homeKitShutdownDelaySeconds) != nil else {
            return 5
        }
        return min(max(userDefaults.integer(forKey: AppSettingsKey.homeKitShutdownDelaySeconds), 0), 5)
    }

    private static func loadSelectedPlugID(from userDefaults: UserDefaults) -> String? {
        guard let home = userDefaults.string(forKey: AppSettingsKey.homeKitHomeIdentifier),
              let accessory = userDefaults.string(forKey: AppSettingsKey.homeKitAccessoryIdentifier),
              let service = userDefaults.string(forKey: AppSettingsKey.homeKitServiceIdentifier) else {
            return nil
        }
        return [home, accessory, service].joined(separator: ":")
    }

    private static func isPowerService(_ service: HMService) -> Bool {
        service.serviceType == HMServiceTypeOutlet || service.serviceType == HMServiceTypeSwitch
    }

    private static func writablePowerCharacteristic(in service: HMService) -> HMCharacteristic? {
        service.characteristics.first { characteristic in
            characteristic.characteristicType == HMCharacteristicTypePowerState
                && characteristic.properties.contains(HMCharacteristicPropertyWritable)
        }
    }

    private static func powerState(from value: Any?) -> Bool? {
        if let value = value as? Bool {
            return value
        }
        return (value as? NSNumber)?.boolValue
    }
}

extension HomeKitSmartPlugService: HMHomeManagerDelegate {
    nonisolated func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            hasLoadedHomes = true
            refreshAvailablePlugs()
            let continuations = loadContinuations
            loadContinuations.removeAll()
            continuations.forEach { $0.resume() }
            await configureSelectedPlugMonitoring()
        }
    }
}

extension HomeKitSmartPlugService: HMAccessoryDelegate {
    nonisolated func accessory(
        _ accessory: HMAccessory,
        service: HMService,
        didUpdateValueFor characteristic: HMCharacteristic
    ) {
        guard characteristic.characteristicType == HMCharacteristicTypePowerState else { return }

        let accessoryIdentifier = accessory.uniqueIdentifier
        let serviceIdentifier = service.uniqueIdentifier
        let powerState: Bool?
        if let value = characteristic.value as? Bool {
            powerState = value
        } else {
            powerState = (characteristic.value as? NSNumber)?.boolValue
        }

        guard let powerState else { return }

        Task { @MainActor [weak self] in
            guard let self,
                  let identifiers = selectedIdentifiers(),
                  identifiers.accessory == accessoryIdentifier,
                  identifiers.service == serviceIdentifier else {
                return
            }

            selectedPlugIsOn = powerState
            errorMessage = nil
        }
    }
}
