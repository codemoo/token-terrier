import Foundation
import Observation
import ServiceManagement

/// SwiftUI-friendly wrapper around `SMAppService.mainApp` for the
/// "로그인 시 자동 시작" toggle. macOS 13+ exposes a per-app login-item API
/// that doesn't need a separate helper bundle — `register()` adds us to the
/// user's Login Items list, `unregister()` removes us.
///
/// Status changes happen out-of-process (the user can also flip the switch
/// from System Settings → General → Login Items), so we re-read the live
/// status whenever the SwiftUI scene appears.
@MainActor
@Observable
final class LaunchAtLoginController {
    private let service = SMAppService.mainApp

    var isEnabled: Bool {
        didSet {
            guard isEnabled != (service.status == .enabled) else { return }
            apply(isEnabled)
        }
    }

    init() {
        isEnabled = service.status == .enabled
    }

    /// Push the desired state into ServiceManagement. Failures are surfaced
    /// to the console but the toggle reverts so SwiftUI stays consistent.
    private func apply(_ desired: Bool) {
        do {
            if desired {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            NSLog("[TokenTerrier] login-item update failed: \(error)")
            // Roll back the @Observable property so the UI reflects truth.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isEnabled = self.service.status == .enabled
            }
        }
    }

    /// Re-syncs the published `isEnabled` from the live service status.
    /// Call when the Settings window appears in case the user toggled the
    /// matching switch from System Settings.
    func refresh() {
        let live = service.status == .enabled
        if live != isEnabled { isEnabled = live }
    }
}
