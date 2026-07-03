import SwiftUI
import TokenUsageCore

/// Right-hand master-detail panel listing every per-account row for a provider.
/// Phase 1 renders Claude's claude-swap accounts; Codex reuses the same view in
/// Phase 2 once the daemon ships codex `accounts[]`.
struct AccountDetailPanel: View {
    let provider: Provider
    let accounts: [AccountUsage]
    /// Tokens/hour for the currently active account (aggregate burn). Non-active
    /// accounts fall back to their own `tokensPerHour` when present.
    let activeBurnPerHour: Double?
    /// Snapshot-level fallback freshness timestamp, used when an individual
    /// account has no `lastRefreshAt` of its own.
    var accountsUpdatedAt: String?
    var onClose: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if accounts.isEmpty {
                Text("계정 정보 없음")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(accounts, id: \.number) { account in
                            accountRow(account)
                        }
                    }
                    .padding(12)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var header: some View {
        HStack {
            Text(provider == .claude ? "Claude 계정" : "Codex 계정")
                .font(.subheadline.bold())
            Spacer()
            Button {
                onClose?()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("계정 패널 닫기")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func accountRow(_ account: AccountUsage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: account.active ? "largecircle.fill.circle" : "circle")
                    .font(.caption2)
                    .foregroundStyle(account.active ? Color.accentColor : .secondary)
                Text(account.email)
                    .font(.caption.bold())
                    .foregroundStyle(account.active ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                if let rate = tokenRateLabel(for: account) {
                    Text(rate)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(Capsule())
                        .accessibilityLabel("시간당 토큰 \(rate)")
                }
            }
            if let label = accountStatusLabel(account.status) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                miniBar(label: "5h", window: account.fiveHour)
                miniBar(label: "주간", window: account.sevenDay)
                resetLine(account)
                freshnessLine(account)
            }
        }
    }

    /// "데이터 갱신: N분 전" line. Prefers the account's own refresh timestamp,
    /// falling back to the snapshot-level one; omitted entirely when both are
    /// missing/unparsable.
    @ViewBuilder
    private func freshnessLine(_ account: AccountUsage) -> some View {
        if let isoString = account.lastRefreshAt ?? accountsUpdatedAt,
           let date = SnapshotDateFormatter.date(from: isoString) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text("데이터 갱신: \(MenuBarContentView.relativePast(date, now: context.date))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    /// Active account shows the live aggregate burn; others show their own
    /// per-account rate when the daemon supplied one, else nothing.
    private func tokenRateLabel(for account: AccountUsage) -> String? {
        if account.active, let burn = activeBurnPerHour {
            return TokenRate.perHourLabel(burn)
        }
        if let perHour = account.tokensPerHour {
            return TokenRate.perHourLabel(perHour)
        }
        return nil
    }

    @ViewBuilder
    private func miniBar(label: String, window: AccountWindow?) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .leading)
            ProgressView(value: window?.usedPct ?? 0)
                .progressViewStyle(.linear)
            Text("\(Int((window?.usedPct ?? 0) * 100))%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)
        }
    }

    /// Reuses the shell's reset formatting so the "남음" countdown stays in sync
    /// with the aggregate rows. Anchored on the 5h window's reset time.
    @ViewBuilder
    private func resetLine(_ account: AccountUsage) -> some View {
        if let resetsAtString = account.fiveHour?.resetsAt,
           let resetsAt = SnapshotDateFormatter.date(from: resetsAtString) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(MenuBarContentView.resetText(at: resetsAt, now: context.date))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
}
