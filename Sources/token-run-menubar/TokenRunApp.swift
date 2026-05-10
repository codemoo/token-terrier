import SwiftUI
import AppKit

@main
struct TokenRunApp: App {
    @State private var appState = AppState()
    @State private var updater = UpdaterController()
    @State private var loginItem = LaunchAtLoginController()
    @NSApplicationDelegateAdaptor(TokenRunAppDelegate.self) private var appDelegate

    init() {
        // Forward the singleton-style updater into the AppDelegate so it can
        // kick off a background check shortly after launch.
        TokenRunAppDelegate.updaterRef = updater
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(appState: appState)
        } label: {
            RunningBedl(
                state: appState.status.aggregateBurnState,
                height: appState.settings.menuBarBedlHeight,
                speed: appState.settings.menuBarBedlSpeed)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(
                appState: appState,
                updater: updater,
                loginItem: loginItem)
                .onAppear {
                    loginItem.refresh()
                    // MenuBarExtra-only apps stay inactive by default, which makes
                    // every text field in the Settings window swallow keystrokes
                    // because the app never becomes the key application. Forcing
                    // activation here makes Settings actually usable.
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
    }
}

final class TokenRunAppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var updaterRef: UpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // .accessory == no Dock icon, but unlike .prohibited the app *can* still
        // activate itself (Settings window can take key focus, text fields work).
        NSApp.setActivationPolicy(.accessory)

        // Sparkle's own scheduler only fires after the configured interval has
        // elapsed since the last check, which means a freshly-installed copy
        // may sit silent until the next interval boundary. Kick off a single
        // background check ~3 s after launch so the very first run also
        // discovers any pending update.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            Self.updaterRef?.checkOnLaunchIfEligible()
        }
    }
}
