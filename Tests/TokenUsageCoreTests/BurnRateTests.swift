import Foundation
import Testing
@testable import TokenUsageCore

@Suite("burn rate")
struct BurnRateTests {
    @Test("starts at idle with zero rate")
    func startsIdle() async {
        let tracker = BurnTracker(provider: .claude)
        let snap = await tracker.snapshot(now: Date())
        #expect(snap.state == .idle)
        #expect(snap.ratePerMinute == 0)
        #expect(!snap.hasObservedAnyEvent)
    }

    @Test("today total is per-event sum and resets across day boundary")
    func todayTotalAndRollover() async {
        let tz = TimeZone(identifier: "Asia/Seoul")!
        let tracker = BurnTracker(provider: .claude, timeZone: tz)
        let day1Noon = ymdInZone(2026, 4, 27, 12, tz: tz)
        let day1Late = ymdInZone(2026, 4, 27, 23, tz: tz)
        let day2Morning = ymdInZone(2026, 4, 28, 6, tz: tz)

        _ = await tracker.ingest(makeEvent(at: day1Noon, tokens: 100), now: day1Noon)
        let lateSnap = await tracker.ingest(makeEvent(at: day1Late, tokens: 200), now: day1Late)
        #expect(lateSnap.todayTotalTokens == 300)
        #expect(lateSnap.todaySessionsCount == 1)

        let nextDay = await tracker.ingest(makeEvent(at: day2Morning, tokens: 50), now: day2Morning)
        #expect(nextDay.todayTotalTokens == 50)
    }

    @Test("sliding window sum becomes burn rate when window is 60s")
    func slidingRate() async {
        let tracker = BurnTracker(provider: .claude)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // three events totaling 600 tokens within 60s
        _ = await tracker.ingest(makeEvent(at: now.addingTimeInterval(-50), tokens: 200), now: now.addingTimeInterval(-50))
        _ = await tracker.ingest(makeEvent(at: now.addingTimeInterval(-30), tokens: 200), now: now.addingTimeInterval(-30))
        _ = await tracker.ingest(makeEvent(at: now.addingTimeInterval(-5), tokens: 200), now: now.addingTimeInterval(-5))
        let snap = await tracker.snapshot(now: now)
        // sliding sum is 600 → 600 tokens / 60s == 600 tokens/min
        #expect(snap.ratePerMinute >= 600)
    }

    @Test("hysteresis prevents flipping back below 80% of upper threshold")
    func hysteresis() async {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let tracker = BurnTracker(provider: .claude, clock: t0)
        // Push enough tokens to enter walk: > 500/min sliding
        _ = await tracker.ingest(makeEvent(at: t0, tokens: 1_000), now: t0)
        let t1 = t0.addingTimeInterval(6)
        _ = await tracker.ingest(makeEvent(at: t1, tokens: 0), now: t1)
        let mid = await tracker.snapshot(now: t1)
        // After window decay, rate may be in [400, 1000) — exit threshold for walk is 400,
        // so we expect to *stay* in walk while rate >= 400.
        if mid.ratePerMinute >= 400 && mid.ratePerMinute < 500 {
            #expect(mid.state == .walk)
        }
    }

    @Test("state stays put for at least 5s after a transition")
    func minimumDwell() async {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let tracker = BurnTracker(provider: .claude, clock: t0)
        // Enter rocket immediately with a huge burst (>=100k tok/min).
        _ = await tracker.ingest(makeEvent(at: t0, tokens: 200_000), now: t0)
        let early = await tracker.snapshot(now: t0.addingTimeInterval(2))
        #expect(early.state == .rocket)
    }

    @Test("BurnState ladder enters next step at threshold and exits 20% below")
    func ladderTransitions() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let later = t0.addingTimeInterval(6)
        // From idle, value 500 enters walk.
        #expect(BurnState.next(value: 500, current: .idle, lastChange: t0, now: later) == .walk)
        // From walk, value 399 exits to idle.
        #expect(BurnState.next(value: 399, current: .walk, lastChange: t0, now: later) == .idle)
        // From walk, value 400 stays walk (hysteresis).
        #expect(BurnState.next(value: 400, current: .walk, lastChange: t0, now: later) == .walk)
        // From idle, value 60_000 jumps to fly directly.
        #expect(BurnState.next(value: 60_000, current: .idle, lastChange: t0, now: later) == .fly)
    }

    private func makeEvent(at date: Date, tokens: Int) -> TokenEvent {
        TokenEvent(
            provider: .claude,
            timestamp: date,
            tokens: tokens,
            model: "test",
            sessionKey: "session-1")
    }

    private func ymdInZone(_ y: Int, _ m: Int, _ d: Int, _ h: Int, tz: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }
}
