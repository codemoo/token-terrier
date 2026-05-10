import Foundation

extension UsageSnapshot {
    /// Returns a new snapshot with burn-rate / today / data-source fields replaced from a
    /// `BurnSnapshot`. All other fields are copied unchanged. The `seq` is preserved unless
    /// `seq:` is supplied — burn deltas can re-publish under the same seq or bump it via
    /// the caller (UsageState owns the monotonic sequence).
    public func with(burn: BurnSnapshot, seq newSeq: Int? = nil, generatedAtUTC: String? = nil) -> UsageSnapshot {
        let nextDataSource: SnapshotDataSource = {
            switch status.dataSource {
            case .apiOnly:
                return burn.hasObservedAnyEvent ? .apiAndJsonl : .apiOnly
            case .apiAndJsonl, .jsonlOnly:
                return status.dataSource
            }
        }()
        let nextStatus = SnapshotStatus(
            state: status.state,
            dataSource: nextDataSource,
            stale: status.stale)
        return UsageSnapshot(
            schema: schema,
            seq: newSeq ?? seq,
            generatedAtUTC: generatedAtUTC ?? self.generatedAtUTC,
            producerID: producerID,
            producerTimeZone: producerTimeZone,
            provider: provider,
            burnRatePerMinute: burn.ratePerMinute,
            burnState: burn.state.rawValue,
            todayTotalTokens: burn.todayTotalTokens,
            todaySessions: burn.todaySessionsCount,
            rolling5h: rolling5h,
            weekly: weekly,
            quotaWindows: quotaWindows,
            credits: credits,
            extras: extras,
            status: nextStatus)
    }
}
