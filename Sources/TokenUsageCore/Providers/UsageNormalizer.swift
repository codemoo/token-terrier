import Foundation

/// Normalizes provider-specific API payloads into SSE snapshots.
public enum UsageNormalizer {
    /// Normalizes a raw Claude usage response.
    public static func normalizeClaude(
        _ response: ClaudeUsageResponse,
        credential: OAuthCredential,
        seq: Int,
        producer: ProducerInfo,
        now: Date)
        -> UsageSnapshot
    {
        let generatedAt = SnapshotDateFormatter.string(from: now)
        let fiveHour = windowFromClaude(response.fiveHour, now: now)
        let weekly = windowFromClaude(response.sevenDay, now: now)
        var quotaWindows: [QuotaWindow] = []
        if let sonnet = response.sevenDaySonnet {
            quotaWindows.append(quotaWindowFromClaude(label: "sonnet", window: sonnet))
        }
        if let opus = response.sevenDayOpus {
            quotaWindows.append(quotaWindowFromClaude(label: "opus", window: opus))
        }
        return UsageSnapshot(
            seq: seq,
            generatedAtUTC: generatedAt,
            producerID: producer.id,
            producerTimeZone: producer.timeZone,
            provider: .claude,
            rolling5h: fiveHour,
            weekly: weekly,
            quotaWindows: quotaWindows,
            credits: nil,
            extras: SnapshotExtras(
                loginMethod: nil,
                accountEmail: nil,
                rateLimitTier: credential.rateLimitTier,
                extraRateWindows: response.extraRateWindows),
            status: SnapshotStatus(state: .ok, stale: false))
    }

    /// Normalizes a raw Codex usage response.
    public static func normalizeCodex(
        _ response: CodexUsageResponse,
        credential: OAuthCredential,
        seq: Int,
        producer: ProducerInfo,
        now: Date)
        -> UsageSnapshot
    {
        let generatedAt = SnapshotDateFormatter.string(from: now)
        let rolling = windowFromCodex(response.primary, now: now)
        let weekly = windowFromCodex(response.secondary, now: now)
        var windows: [QuotaWindow] = []
        if let tertiary = response.tertiary {
            let scope = (tertiary.windowSeconds ?? 0) >= 7 * 24 * 60 * 60 ? "weekly" : "rolling"
            windows.append(quotaWindowFromCodex(label: "tertiary", scope: scope, window: tertiary))
        }
        let credits: Credits?
        if let remaining = response.credits?.remaining {
            let updatedAt = response.credits?.updatedAt.map(SnapshotDateFormatter.string(from:)) ?? generatedAt
            credits = Credits(remaining: remaining, updatedAt: updatedAt)
        } else {
            credits = nil
        }
        return UsageSnapshot(
            seq: seq,
            generatedAtUTC: generatedAt,
            producerID: producer.id,
            producerTimeZone: producer.timeZone,
            provider: .codex,
            rolling5h: rolling,
            weekly: weekly,
            quotaWindows: windows,
            credits: credits,
            extras: SnapshotExtras(
                loginMethod: response.loginMethod,
                accountEmail: response.accountEmail ?? credential.accountEmail,
                rateLimitTier: nil,
                extraRateWindows: []),
            status: SnapshotStatus(state: .ok, stale: false))
    }

    private static func windowFromClaude(_ window: ClaudeUsageWindow?, now: Date) -> RollingWindow {
        guard let window else { return .empty }
        let resetDate = window.resetsAt.flatMap(SnapshotDateFormatter.date(from:))
        return RollingWindow(
            usedPct: percentToRatio(window.utilization),
            remainingSeconds: SnapshotDateFormatter.remainingSeconds(until: resetDate, now: now),
            resetsAt: resetDate.map(SnapshotDateFormatter.string(from:)))
    }

    private static func windowFromCodex(_ window: CodexUsageWindow?, now: Date) -> RollingWindow {
        guard let window else { return .empty }
        return RollingWindow(
            usedPct: percentToRatio(window.usedPercent ?? 0),
            remainingSeconds: SnapshotDateFormatter.remainingSeconds(until: window.resetsAt, now: now),
            resetsAt: window.resetsAt.map(SnapshotDateFormatter.string(from:)))
    }

    private static func quotaWindowFromClaude(label: String, window: ClaudeUsageWindow) -> QuotaWindow {
        let resetDate = window.resetsAt.flatMap(SnapshotDateFormatter.date(from:))
        return QuotaWindow(
            label: label,
            scope: "weekly",
            usedPct: percentToRatio(window.utilization),
            resetsAt: resetDate.map(SnapshotDateFormatter.string(from:)))
    }

    private static func quotaWindowFromCodex(label: String, scope: String, window: CodexUsageWindow) -> QuotaWindow {
        QuotaWindow(
            label: label,
            scope: scope,
            usedPct: percentToRatio(window.usedPercent ?? 0),
            resetsAt: window.resetsAt.map(SnapshotDateFormatter.string(from:)))
    }

    private static func percentToRatio(_ percent: Double) -> Double {
        min(max(percent / 100, 0), 1)
    }
}
