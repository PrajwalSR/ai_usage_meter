import SwiftUI

/// The popover panel. A pure function of the values passed in: no SwiftUI state
/// macros (they didn't build with Command Line Tools alone), and `now` is passed
/// in so expiry and "… ago" text are recomputed on every redraw.
struct UsagePanel: View {
    let report: UsageReport?
    let isScanning: Bool
    let isWatching: Bool
    let liveClaudeEnabled: Bool
    let webSignedIn: Bool
    let onSignInToClaudeWeb: () -> Void
    let launchAtLoginAvailable: Bool
    let launchesAtLogin: Bool
    let errorText: String?
    let now: Date
    let onRefresh: () -> Void
    let onToggleLiveClaude: (Bool) -> Void
    let onToggleLaunchAtLogin: (Bool) -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            if let report {
                if let codex = report.codex { ProviderCard(reading: codex, now: now) }
                if let claude = report.claude { ProviderCard(reading: claude, now: now) }
                Divider()
                footer(report)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading local logs…").foregroundStyle(.secondary)
                }
                .padding(.vertical, 10)
            }
        }
        .padding(14)
        .frame(width: 350)
    }

    private var header: some View {
        HStack {
            Text("AI Usage Meter").font(.headline)
            Spacer()
            if isScanning {
                ProgressView().controlSize(.small)
            } else {
                Button(action: onRefresh) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help(liveClaudeEnabled
                          ? "Re-read local logs and check Claude usage with Anthropic."
                          : "Re-read local logs.")
            }
        }
    }

    private func footer(_ report: UsageReport) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Circle()
                    .fill(isWatching ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
                Text(isWatching ? "Watching logs · updates automatically"
                                : "Not watching logs · press ⟳ to update")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Text("Updated \(Fmt.age(report.scannedAt, now: now)) · " + filesNote(report))
                .font(.caption2).foregroundStyle(.secondary)

            ForEach(Array(report.errors.prefix(3).enumerated()), id: \.offset) { _, err in
                Text(err).font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let errorText {
                Text(errorText).font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !webSignedIn {
                Button(action: onSignInToClaudeWeb) {
                    Text("Sign in to Claude for live updates").font(.caption)
                }
                .buttonStyle(.link)
                .help("Opens Anthropic's own sign-in page in a window this app owns, "
                      + "then reads your usage from claude.ai every minute.")
            }

            Toggle(isOn: Binding(get: { liveClaudeEnabled }, set: { onToggleLiveClaude($0) })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Check Claude usage live").font(.caption)
                    Text("Uses your Claude Code login · asks Anthropic when you open this panel")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)

            if launchAtLoginAvailable {
                Toggle(isOn: Binding(get: { launchesAtLogin }, set: { onToggleLaunchAtLogin($0) })) {
                    Text("Open at login").font(.caption)
                }
                .toggleStyle(.checkbox)
            }

            HStack {
                Button("Quit", action: onQuit).buttonStyle(.borderless).font(.caption)
                Spacer()
            }
        }
    }

    /// "no new data" means every log was already indexed and the pass was cheap.
    private func filesNote(_ report: UsageReport) -> String {
        let read = (report.codex?.filesReadThisPass ?? 0) + (report.claude?.filesReadThisPass ?? 0)
        return read == 0 ? "no new data" : "\(read) file\(read == 1 ? "" : "s") read"
    }
}

struct ProviderCard: View {
    let reading: ProviderReading
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(reading.providerName).font(.subheadline.weight(.semibold))
                if let plan = planLabel {
                    Text(plan).font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
            }

            allowanceSection

            VStack(alignment: .leading, spacing: 2) {
                Text(reading.provider == .claude ? "Claude Code tokens on this Mac"
                                                 : "Codex tokens on this Mac")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                row("Last 5 hours", reading.last5Hours)
                row("Last 7 days", reading.last7Days)
            }
            .padding(.top, 3)

            if let newest = reading.newestLogEntry {
                Text("Newest entry \(Fmt.age(newest, now: now)) · \(reading.filesSeen) files")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("No usage entries in the last 7 days · \(reading.filesSeen) files")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
    }

    /// Badge next to the provider name.
    ///
    /// Codex logs give an internal id (`prolite` = ChatGPT Pro 5x). Claude's data
    /// has no plan at all, so its badge is an optional setting, hidden when unset:
    ///
    ///     defaults write local.aiusagemeter claudePlanLabel "Pro"
    private var planLabel: String? {
        if reading.provider == .claude {
            let label = UserDefaults.standard.string(forKey: "claudePlanLabel")
            return (label?.isEmpty ?? true) ? nil : label
        }
        guard let raw = reading.planType else { return nil }
        switch raw {
        case "prolite": return "Pro 5x"
        case "pro": return "Pro"
        case "plus": return "Plus"
        case "team": return "Team"
        default: return raw
        }
    }

    /// Names the limit so it isn't mistaken for general chat usage. For Codex it
    /// includes `limit_id` when it isn't the usual "codex".
    private func limitName(_ w: AllowanceWindow) -> String {
        switch reading.provider {
        case .claude:
            return "\(w.windowLabel) limit"
        case .codex:
            if let id = w.limitId, id != "codex" { return "\(w.windowLabel) Codex limit (\(id))" }
            return "\(w.windowLabel) Codex limit"
        }
    }

    @ViewBuilder
    private var allowanceSection: some View {
        switch reading.display(now: now) {
        case .available(let head, let others, let source):
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(Int(head.usedPercent.rounded()))%")
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .foregroundStyle(tint(head.usedPercent))
                    Text("of \(limitName(head)) used")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ProgressView(value: min(head.usedPercent, 100), total: 100)
                    .tint(tint(head.usedPercent))
                if let resets = head.resetsAt {
                    Text("Resets \(Fmt.until(resets, now: now)) · \(Fmt.clock(resets))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                // Other still-valid windows from the same reading, e.g. Claude's
                // 7-day window under its 5-hour one.
                ForEach(Array(others.enumerated()), id: \.offset) { _, w in
                    HStack(spacing: 6) {
                        Text(w.windowLabel.capitalized)
                            .font(.caption).foregroundStyle(.secondary)
                        ProgressView(value: min(w.usedPercent, 100), total: 100)
                            .tint(tint(w.usedPercent))
                        Text("\(Int(w.usedPercent.rounded()))%")
                            .font(.caption.monospacedDigit())
                        if let r = w.resetsAt {
                            Text(Fmt.until(r, now: now)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                Text(Fmt.sourceLine(source, now: now))
                    .font(.caption2).foregroundStyle(.secondary)
            }

        case .expired(let source):
            VStack(alignment: .leading, spacing: 4) {
                Text("Usage unknown")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.orange)
                Text(expiredExplanation(source.source))
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Fmt.sourceLine(source, now: now))
                    .font(.caption2).foregroundStyle(.orange)
            }

        case .unavailable:
            VStack(alignment: .leading, spacing: 4) {
                Text("Usage unavailable")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                Text(reading.unavailableNote)
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// What happens next depends on where the reading came from.
    private func expiredExplanation(_ source: ReadingSource) -> String {
        let base = "The last reading's limit has reset since it was taken, so the current "
                 + "figure isn't known yet. "
        switch source {
        case .codexLog: return base + "It updates the next time Codex runs."
        case .anthropicLive: return base + "It updates at the next live check."
        case .claudeWeb: return base + "It updates at the next check with claude.ai."
        case .claudeStatusLine: return base + "It updates the next time Claude Code runs in a terminal."
        }
    }

    private func row(_ label: String, _ t: TokenTotals) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text("\(Fmt.tokens(t.total)) tok").font(.caption.monospacedDigit())
            Text("· \(t.messages) msg")
                .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
        }
    }

    private func tint(_ pct: Double) -> Color {
        pct >= 90 ? .red : (pct >= 75 ? .orange : .accentColor)
    }
}
