import Foundation

/// Computes summary averages across claude-swap-managed accounts.
public enum AccountAverages {
    public static func fiveHour(_ accounts: [AccountUsage]) -> Double? {
        fiveHourWindow(accounts)?.usedPct
    }

    public static func sevenDay(_ accounts: [AccountUsage]) -> Double? {
        sevenDayWindow(accounts)?.usedPct
    }

    public static func fiveHourWindow(_ accounts: [AccountUsage], now: Date = Date()) -> RollingWindow? {
        window(accounts, \.fiveHour, now: now)
    }

    public static func sevenDayWindow(_ accounts: [AccountUsage], now: Date = Date()) -> RollingWindow? {
        window(accounts, \.sevenDay, now: now)
    }

    private static func window(_ accounts: [AccountUsage], _ keyPath: KeyPath<AccountUsage, AccountWindow?>, now: Date) -> RollingWindow? {
        let windows = accounts
            .filter { $0.status == "ok" }
            .compactMap { $0[keyPath: keyPath] }
        let values = windows.map { min(max($0.usedPct, 0), 1) }
        guard !values.isEmpty else { return nil }
        let resetDate = windows
            .compactMap { $0.resetsAt.flatMap(SnapshotDateFormatter.date(from:)) }
            .min()
        return RollingWindow(
            usedPct: values.reduce(0, +) / Double(values.count),
            remainingSeconds: SnapshotDateFormatter.remainingSeconds(until: resetDate, now: now),
            resetsAt: resetDate.map(SnapshotDateFormatter.string(from:)))
    }
}
