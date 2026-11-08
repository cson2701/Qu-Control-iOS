import Combine
import XCTest
@testable import Qu_Controller

@MainActor
final class MixerShutdownCoordinatorTests: XCTestCase {
    func testShutdownWaitsForConfiguredDelayBeforeTurningOffPlug() async throws {
        let recorder = ShutdownEventRecorder()
        let controller = StubMixerController(recorder: recorder)
        let powerController = StubPowerController(
            isEnabled: true,
            delaySeconds: 3,
            hasSelectedPlug: true,
            recorder: recorder
        )
        let coordinator = MixerShutdownCoordinator(
            controller: controller,
            powerController: powerController,
            sleep: { duration in
                recorder.events.append("delay")
                recorder.delays.append(duration)
            }
        )

        let result = try await coordinator.shutdown()

        XCTAssertEqual(recorder.events, ["mixer", "delay", "plug"])
        XCTAssertEqual(recorder.delays, [.seconds(3)])
        XCTAssertTrue(result.didTurnOffPlug)
    }

    func testZeroDelayTurnsOffPlugWithoutSleeping() async throws {
        let recorder = ShutdownEventRecorder()
        let coordinator = MixerShutdownCoordinator(
            controller: StubMixerController(recorder: recorder),
            powerController: StubPowerController(
                isEnabled: true,
                delaySeconds: 0,
                hasSelectedPlug: true,
                recorder: recorder
            ),
            sleep: { _ in
                XCTFail("A zero-second delay should not invoke sleep")
            }
        )

        let result = try await coordinator.shutdown()

        XCTAssertEqual(recorder.events, ["mixer", "plug"])
        XCTAssertTrue(result.didTurnOffPlug)
    }

    func testDisabledPowerOffPreservesMixerOnlyBehavior() async throws {
        let recorder = ShutdownEventRecorder()
        let coordinator = MixerShutdownCoordinator(
            controller: StubMixerController(recorder: recorder),
            powerController: StubPowerController(
                isEnabled: false,
                delaySeconds: 5,
                hasSelectedPlug: false,
                recorder: recorder
            ),
            sleep: { _ in XCTFail("Disabled power-off should not sleep") }
        )

        let result = try await coordinator.shutdown()

        XCTAssertEqual(recorder.events, ["mixer"])
        XCTAssertFalse(result.didTurnOffPlug)
    }

    func testMixerFailureLeavesPlugOn() async {
        let recorder = ShutdownEventRecorder()
        let controller = StubMixerController(recorder: recorder)
        controller.shutdownError = TestFailure.mixer
        let coordinator = MixerShutdownCoordinator(
            controller: controller,
            powerController: StubPowerController(
                isEnabled: true,
                delaySeconds: 2,
                hasSelectedPlug: true,
                recorder: recorder
            ),
            sleep: { _ in XCTFail("A failed mixer command should not sleep") }
        )

        do {
            _ = try await coordinator.shutdown()
            XCTFail("Expected mixer shutdown to fail")
        } catch {
            XCTAssertEqual(error as? TestFailure, .mixer)
        }

        XCTAssertEqual(recorder.events, ["mixer"])
    }

    func testMissingPlugConfigurationIsReportedAfterMixerShutdown() async {
        let recorder = ShutdownEventRecorder()
        let coordinator = MixerShutdownCoordinator(
            controller: StubMixerController(recorder: recorder),
            powerController: StubPowerController(
                isEnabled: true,
                delaySeconds: 2,
                hasSelectedPlug: false,
                recorder: recorder
            ),
            sleep: { _ in XCTFail("Missing configuration should not sleep") }
        )

        do {
            _ = try await coordinator.shutdown()
            XCTFail("Expected missing configuration to fail")
        } catch let error as MixerShutdownSequenceError {
            guard case .missingPlugConfiguration = error else {
                return XCTFail("Unexpected sequence error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(recorder.events, ["mixer"])
    }

    func testPlugFailureIsReportedAfterDelay() async {
        let recorder = ShutdownEventRecorder()
        let powerController = StubPowerController(
            isEnabled: true,
            delaySeconds: 1,
            hasSelectedPlug: true,
            recorder: recorder
        )
        powerController.powerOffError = TestFailure.plug
        let coordinator = MixerShutdownCoordinator(
            controller: StubMixerController(recorder: recorder),
            powerController: powerController,
            sleep: { _ in recorder.events.append("delay") }
        )

        do {
            _ = try await coordinator.shutdown()
            XCTFail("Expected plug power-off to fail")
        } catch let error as MixerShutdownSequenceError {
            guard case .powerOffFailed = error else {
                return XCTFail("Unexpected sequence error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(recorder.events, ["mixer", "delay", "plug"])
    }
}

@MainActor
private final class ShutdownEventRecorder {
    var events: [String] = []
    var delays: [Duration] = []
}

@MainActor
private final class StubPowerController: PostShutdownPowerControlling {
    let isAutomaticPowerOffEnabled: Bool
    let delaySeconds: Int
    let hasSelectedPlug: Bool
    var powerOffError: Error?

    private let recorder: ShutdownEventRecorder

    init(
        isEnabled: Bool,
        delaySeconds: Int,
        hasSelectedPlug: Bool,
        recorder: ShutdownEventRecorder
    ) {
        isAutomaticPowerOffEnabled = isEnabled
        self.delaySeconds = delaySeconds
        self.hasSelectedPlug = hasSelectedPlug
        self.recorder = recorder
    }

    func turnOffSelectedPlug() async throws {
        recorder.events.append("plug")
        if let powerOffError {
            throw powerOffError
        }
    }
}

@MainActor
private final class StubMixerController: MixerController {
    let channels: [MixerChannelState] = []
    var connectionState = MixerConnectionState(phase: .connected, message: "Connected", endpoint: nil)
    let faderWaveState = FaderWaveState.ready
    let channelsPublisher = Just<[MixerChannelState]>([]).eraseToAnyPublisher()
    let connectionStatePublisher = Just(
        MixerConnectionState(phase: .connected, message: "Connected", endpoint: nil)
    ).eraseToAnyPublisher()
    let faderWaveStatePublisher = Just(FaderWaveState.ready).eraseToAnyPublisher()
    var shutdownError: Error?

    private let recorder: ShutdownEventRecorder

    init(recorder: ShutdownEventRecorder) {
        self.recorder = recorder
    }

    func connect(to endpoint: MixerEndpoint) async {}
    func disconnect() {}

    func shutdownMixer() async throws {
        recorder.events.append("mixer")
        if let shutdownError {
            throw shutdownError
        }
    }

    func setLevel(for channelID: MixerChannelID, level: FaderLevel) {}
    func setMute(for channelID: MixerChannelID, isMuted: Bool) {}
    func setSignalMonitoringEnabled(_ isEnabled: Bool) {}
    func startFaderWave(configuration: FaderWaveConfiguration) {}
    func stopFaderWave() {}
}

private enum TestFailure: Error, Equatable {
    case mixer
    case plug
}
