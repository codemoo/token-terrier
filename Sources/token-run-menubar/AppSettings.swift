import Foundation
import Observation
import TokenUsageCore

/// User-mutable connection settings, persisted to UserDefaults under a single dict key.
///
/// Bearer tokens are kept here for Day-4 simplicity. Day-5+ should move them to Keychain.
@Observable
@MainActor
public final class AppSettings {
    /// Connection mode applied to the Claude provider only.
    public var claudeConnectionMode: ConnectionMode { didSet { persist() } }
    /// Connection mode applied to the Codex provider only.
    public var codexConnectionMode: ConnectionMode { didSet { persist() } }
    public var remoteURL: String { didSet { persist() } }
    public var loopbackURL: String { didSet { persist() } }
    public var claudeBearer: String { didSet { persist() } }
    public var codexBearer: String { didSet { persist() } }
    /// Menu-bar Bedlington Terrier height in points. Clamped to a sensible range so a
    /// fat-fingered slider can't make the icon vanish or eat the menu bar.
    public var menuBarBedlHeight: Double { didSet { persist() } }
    /// Global multiplier applied to the Bedlington Terrier loop duration.
    public var menuBarBedlSpeed: Double { didSet { persist() } }
    public static let menuBarBedlHeightRange: ClosedRange<Double> = 12...28
    public static let menuBarBedlHeightDefault: Double = 16
    public static let menuBarBedlSpeedRange: ClosedRange<Double> = 0.5...2.0
    public static let menuBarBedlSpeedDefault: Double = 1.0

    private static let storeKey = "TokenRunMenuBar.Settings.v1"
    private static let defaultRemote = ""
    private static let defaultLoopback = "http://127.0.0.1:18910"

    public init() {
        let store = UserDefaults.standard.dictionary(forKey: Self.storeKey) ?? [:]
        // Migration: pre-v0.9 stored a single `mode` key for both providers.
        // Honour it as the seed when the per-provider keys aren't present yet.
        let legacy = ConnectionMode(rawValue: (store["mode"] as? String) ?? "") ?? .auto
        claudeConnectionMode = ConnectionMode(rawValue: (store["claudeMode"] as? String) ?? "") ?? legacy
        codexConnectionMode  = ConnectionMode(rawValue: (store["codexMode"]  as? String) ?? "") ?? legacy
        remoteURL = (store["remoteURL"] as? String) ?? Self.defaultRemote
        loopbackURL = (store["loopbackURL"] as? String) ?? Self.defaultLoopback
        claudeBearer = (store["claudeBearer"] as? String) ?? ""
        codexBearer = (store["codexBearer"] as? String) ?? ""
        let storedHeight = (store["bedlHeight"] as? Double) ?? Self.menuBarBedlHeightDefault
        menuBarBedlHeight = storedHeight.clamped(to: Self.menuBarBedlHeightRange)
        let storedSpeed = (store["bedlSpeed"] as? Double) ?? Self.menuBarBedlSpeedDefault
        menuBarBedlSpeed = storedSpeed.clamped(to: Self.menuBarBedlSpeedRange)

        // First run: try to seed bearer tokens from the local daemon's tokens file.
        if claudeBearer.isEmpty, codexBearer.isEmpty {
            seedFromLocalDaemonTokens()
        }
    }

    /// Per-provider mode lookup — what the rest of the app should call.
    public func mode(for provider: Provider) -> ConnectionMode {
        switch provider {
        case .claude: return claudeConnectionMode
        case .codex:  return codexConnectionMode
        }
    }

    private func persist() {
        let dict: [String: Any] = [
            "claudeMode": claudeConnectionMode.rawValue,
            "codexMode":  codexConnectionMode.rawValue,
            "remoteURL": remoteURL,
            "loopbackURL": loopbackURL,
            "claudeBearer": claudeBearer,
            "codexBearer": codexBearer,
            "bedlHeight": menuBarBedlHeight,
            "bedlSpeed": menuBarBedlSpeed,
        ]
        UserDefaults.standard.set(dict, forKey: Self.storeKey)
    }

    /// On the producer Mac itself the daemon writes `~/.config/token-usage/tokens.json`.
    /// If we find that file we seed the bearer tokens automatically so the menu bar
    /// works out of the box on the producer host.
    private func seedFromLocalDaemonTokens() {
        let url = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".config/token-usage/tokens.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else {
            return
        }
        if claudeBearer.isEmpty, let value = object["claude"] { claudeBearer = value }
        if codexBearer.isEmpty, let value = object["codex"] { codexBearer = value }
    }

    public func bearer(for provider: String) -> String {
        switch provider {
        case "claude": return claudeBearer
        case "codex": return codexBearer
        default: return ""
        }
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
