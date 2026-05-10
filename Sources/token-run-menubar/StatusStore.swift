import Foundation
import Observation
import TokenUsageCore

/// Per-provider connection state shown in the menu bar.
public enum ProviderConnectionState: String, Sendable {
    case idle           // 시작 전
    case connecting     // SSE 연결 시도 중
    case connected      // 첫 snapshot 받음
    case stale          // 마지막 snapshot 60s 이상 지남
    case offline        // 연결 끊김 + 재시도 중
}

/// Snapshot + connection state for one provider, plus the active source label.
public struct ProviderStatus: Sendable {
    public var snapshot: UsageSnapshot?
    public var state: ProviderConnectionState
    public var activeSource: String?      // "loopback", "remote", "local-direct"
    public var lastUpdated: Date?
}

/// Holds the latest data for both providers. Mutated on the main actor only.
@Observable
@MainActor
public final class StatusStore {
    public var claude: ProviderStatus = ProviderStatus(snapshot: nil, state: .idle, activeSource: nil, lastUpdated: nil)
    public var codex: ProviderStatus = ProviderStatus(snapshot: nil, state: .idle, activeSource: nil, lastUpdated: nil)

    public init() {}

    public func update(provider: Provider, snapshot: UsageSnapshot, source: String) {
        var status = self[provider]
        status.snapshot = snapshot
        status.state = .connected
        status.activeSource = source
        status.lastUpdated = Date()
        self[provider] = status
    }

    public func setState(provider: Provider, _ state: ProviderConnectionState, source: String? = nil) {
        var status = self[provider]
        status.state = state
        if let source { status.activeSource = source }
        self[provider] = status
    }

    public subscript(provider: Provider) -> ProviderStatus {
        get {
            switch provider {
            case .claude: return claude
            case .codex: return codex
            }
        }
        set {
            switch provider {
            case .claude: claude = newValue
            case .codex: codex = newValue
            }
        }
    }

    /// Returns the highest burn state across both providers — used to choose a
    /// menu-bar icon that reflects "the loudest" provider.
    public var aggregateBurnState: BurnState {
        let candidates = [claude.snapshot?.burnState, codex.snapshot?.burnState]
            .compactMap { $0 }
            .compactMap { BurnState(rawValue: $0) }
        return candidates.max() ?? .idle
    }
}

extension BurnState: Comparable {
    public static func < (lhs: BurnState, rhs: BurnState) -> Bool {
        let order: [BurnState] = [.idle, .walk, .jog, .run, .fly, .rocket]
        let li = order.firstIndex(of: lhs) ?? 0
        let ri = order.firstIndex(of: rhs) ?? 0
        return li < ri
    }
}
