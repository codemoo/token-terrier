import Foundation

/// User-selectable connection mode for the menu-bar consumer.
///
/// `auto` walks loopback → remote (no automatic local-direct fallback —
/// users opt into that mode explicitly because it bypasses the daemon
/// entirely and changes the producer story).
/// `remote` skips the loopback probe (useful when the menu bar is on a different Mac).
/// `loopback` pins to the local daemon (`127.0.0.1:18910`) and never uses a remote URL.
/// `localDirect` reads OAuth credentials and JSONL out of `~/.claude` /
/// `~/.codex` directly — same stack as the daemon, just running in-process.
public enum ConnectionMode: String, CaseIterable, Codable, Sendable {
    case auto
    case remote
    case loopback
    case localDirect

    public var label: String {
        switch self {
        case .auto: return "자동 (Loopback → 원격)"
        case .remote: return "원격 서버"
        case .loopback: return "로컬 daemon (127.0.0.1)"
        case .localDirect: return "로컬 직접 read (daemon 없이)"
        }
    }

    public var shortLabel: String {
        switch self {
        case .auto: return "자동"
        case .remote: return "원격"
        case .loopback: return "로컬"
        case .localDirect: return "직접"
        }
    }
}
