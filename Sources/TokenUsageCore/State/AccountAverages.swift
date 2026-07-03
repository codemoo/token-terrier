import Foundation

/// Computes summary averages across claude-swap-managed accounts.
public enum AccountAverages {
    public static func fiveHour(_ accounts: [AccountUsage]) -> Double? {
        mean(accounts, \.fiveHour)
    }

    public static func sevenDay(_ accounts: [AccountUsage]) -> Double? {
        mean(accounts, \.sevenDay)
    }

    private static func mean(_ accounts: [AccountUsage], _ keyPath: KeyPath<AccountUsage, AccountWindow?>) -> Double? {
        let values = accounts
            .filter { $0.status == "ok" }
            .compactMap { $0[keyPath: keyPath]?.usedPct }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}
