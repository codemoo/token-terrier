import AppKit
import Foundation
import Observation
import Sparkle

/// SwiftUI-friendly wrapper around `SPUStandardUpdaterController`. Sparkle's own
/// updater is KVO-driven, but `@Observable` doesn't pick that up automatically —
/// this class mirrors the Bool/TimeInterval prefs into observed properties so
/// SwiftUI Toggles/Pickers can bind directly.
@MainActor
@Observable
final class UpdaterController {
    private let controller: SPUStandardUpdaterController

    var automaticallyChecksForUpdates: Bool {
        didSet {
            guard automaticallyChecksForUpdates != controller.updater.automaticallyChecksForUpdates else { return }
            controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    var automaticallyDownloadsUpdates: Bool {
        didSet {
            guard automaticallyDownloadsUpdates != controller.updater.automaticallyDownloadsUpdates else { return }
            controller.updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
        }
    }

    /// Update check interval in seconds. Sparkle clamps to ≥ 1 hour.
    var updateCheckIntervalHours: Double {
        didSet {
            let seconds = max(3_600, updateCheckIntervalHours * 3_600)
            guard abs(controller.updater.updateCheckInterval - seconds) > 1 else { return }
            controller.updater.updateCheckInterval = seconds
        }
    }

    var lastUpdateCheckDate: Date? { controller.updater.lastUpdateCheckDate }

    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

    /// Retained so Sparkle (which holds delegates weakly) doesn't drop the
    /// session-finish hook between checks. The delegate is what restores
    /// `.accessory` once the update panel is dismissed.
    private let sessionDelegate = SparkleSessionDelegate()

    init() {
        // First-run defaults: auto-check ON, auto-download ON, hourly cadence.
        // `register(defaults:)` only fills keys the user hasn't explicitly set,
        // so anyone who's already toggled these in Settings keeps their choice.
        UserDefaults.standard.register(defaults: [
            "SUEnableAutomaticChecks": true,
            "SUAutomaticallyUpdate": true,
            "SUScheduledCheckInterval": 3_600.0,
        ])

        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: sessionDelegate)
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = controller.updater.automaticallyDownloadsUpdates
        updateCheckIntervalHours = controller.updater.updateCheckInterval / 3_600
        sessionDelegate.owner = self
    }

    func checkForUpdates() {
        // .accessory apps don't get window focus from NSApp.activate alone:
        // their windows still order beneath whatever is currently frontmost.
        // Briefly switch to .regular so Sparkle's "An update is available…"
        // panel actually surfaces. We flip back to .accessory in
        // `updateSessionDidFinish` so the Dock icon doesn't linger.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    /// Called from a Sparkle delegate hook once the session ends — restores
    /// the accessory presentation so the app goes back to being a menu-bar
    /// citizen with no Dock icon.
    func resignToAccessoryAfterUpdateSession() {
        NSApp.setActivationPolicy(.accessory)
    }

    /// Background check triggered automatically on launch so consumer Macs see
    /// new releases without having to open Settings. Quietly does nothing if
    /// the user has explicitly opted out of automatic checks.
    func checkOnLaunchIfEligible() {
        guard automaticallyChecksForUpdates, controller.updater.canCheckForUpdates else { return }
        controller.updater.checkForUpdatesInBackground()
    }
}

/// Bridges Sparkle's user-driver lifecycle back to the menu-bar app so we
/// can drop the temporary `.regular` activation (and its Dock icon) once
/// the update panel is dismissed — whether the user accepted the update,
/// declined it, or there was nothing to install.
private final class SparkleSessionDelegate: NSObject, SPUStandardUserDriverDelegate {
    weak var owner: UpdaterController?

    func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor [weak owner] in
            owner?.resignToAccessoryAfterUpdateSession()
        }
    }
}
