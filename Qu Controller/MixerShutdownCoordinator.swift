import Foundation

@MainActor
protocol PostShutdownPowerControlling: AnyObject {
    var isAutomaticPowerOffEnabled: Bool { get }
    var delaySeconds: Int { get }
    var hasSelectedPlug: Bool { get }

    func turnOffSelectedPlug() async throws
}

struct MixerShutdownSequenceResult: Equatable {
    let didTurnOffPlug: Bool
}

enum MixerShutdownSequenceError: LocalizedError {
    case missingPlugConfiguration
    case powerOffFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingPlugConfiguration:
            "The mixer shutdown command was sent, but no HomeKit smart plug is selected. The plug was left on."
        case let .powerOffFailed(message):
            "The mixer shutdown command was sent, but the smart plug could not be turned off. The plug may still be on. \(message)"
        }
    }
}

@MainActor
final class MixerShutdownCoordinator {
    typealias Sleep = (Duration) async throws -> Void

    private let controller: MixerController
    private let powerController: PostShutdownPowerControlling
    private let sleep: Sleep

    init(
        controller: MixerController,
        powerController: PostShutdownPowerControlling,
        sleep: @escaping Sleep = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.controller = controller
        self.powerController = powerController
        self.sleep = sleep
    }

    func shutdown() async throws -> MixerShutdownSequenceResult {
        try await controller.shutdownMixer()

        guard powerController.isAutomaticPowerOffEnabled else {
            return MixerShutdownSequenceResult(didTurnOffPlug: false)
        }

        guard powerController.hasSelectedPlug else {
            throw MixerShutdownSequenceError.missingPlugConfiguration
        }

        let delay = min(max(powerController.delaySeconds, 0), 5)
        if delay > 0 {
            try await sleep(.seconds(delay))
        }

        do {
            try await powerController.turnOffSelectedPlug()
            return MixerShutdownSequenceResult(didTurnOffPlug: true)
        } catch {
            throw MixerShutdownSequenceError.powerOffFailed(error.localizedDescription)
        }
    }
}
