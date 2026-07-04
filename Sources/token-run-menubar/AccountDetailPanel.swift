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
        HStack(spacing: 6) {
            Button {
                onClose?()
            } label: {
                Image(systemName: "chevron.backward")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("개요로 돌아가기")
            Text(provider == .claude ? "Claude 계정" : "Codex 계정")
                .font(.subheadline.bold())
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func accountRow(_ account: AccountUsage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            let statusLabel = accountStatusLabel(account.status)
            let hasUsageData = account.fiveHour != nil || account.sevenDay != nil || account.totalTokens != nil || account.tokensPerHour != nil
            HStack(spacing: 4) {
                Image(systemName: account.active ? "largecircle.fill.circle" : "circle")
                    .font(.caption2)
                    .foregroundStyle(account.active ? Color.accentColor : .secondary)
                Text(displayLabel(for: account))
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
            if let label = statusLabel {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if statusLabel == nil || hasUsageData {
                miniBar(label: "5h", window: account.fiveHour)
                miniBar(label: "주간", window: account.sevenDay)
                if let total = account.totalTokens {
                    Text("누적 \(TokenRate.countLabel(total))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func displayLabel(for account: AccountUsage) -> String {
        let trimmed = account.email.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "계정 \(account.number)" : trimmed
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
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 26, alignment: .leading)
                if let window {
                    let usedPct = Self.clampUnit(window.usedPct)
                    ProgressView(value: usedPct)
                        .progressViewStyle(.linear)
                    Text("\(Int(usedPct * 100))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                } else {
                    Text("데이터 없음")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let window {
                if let resetsAtString = window.resetsAt,
                   let resetsAt = SnapshotDateFormatter.date(from: resetsAtString) {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        resetCaption(MenuBarContentView.resetText(at: resetsAt, now: context.date))
                    }
                } else {
                    resetCaption("리셋 정보 없음")
                }
            }
        }
    }

    private func resetCaption(_ text: String) -> some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: 26, height: 0)
            Text(text)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private static func clampUnit(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
