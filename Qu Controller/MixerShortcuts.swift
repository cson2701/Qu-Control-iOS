//
//  MixerShortcuts.swift
//  Qu Controller
//

import AppIntents

struct ShutdownMixerIntent: AppIntent {
    static var title: LocalizedStringResource = "Shut Down Mixer"
    static var description = IntentDescription(
        "Connects to the last used direct mixer or relay endpoint and shuts the mixer down."
    )
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let service = await MainActor.run {
            MixerShutdownShortcutService()
        }
        let result = try await service.shutdownMixerUsingRememberedHost()
        let dialog = IntentDialog("Mixer at \(result.host) was shut down.")

        return .result(dialog: dialog)
    }
}

struct QuControllerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ShutdownMixerIntent(),
            phrases: [
                "Shut down the mixer with \(.applicationName)",
                "Power off my mixer with \(.applicationName)"
            ],
            shortTitle: "Shut Down Mixer",
            systemImageName: "power"
        )
    }
}
