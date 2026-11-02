import SwiftUI
import AppKit

/// Everything the panel needs, passed in as plain values. No SwiftUI state
/// macros (they didn't build with Command Line Tools alone), and `now` is passed
/// in so expiry and "… ago" text are recomputed on every redraw.
struct PanelModel {
    var report: UsageReport?
    var isScanning: Bool
    var isWatching: Bool
    var showingSettings: Bool
    var claudeSignedIn: Bool
    var chatGPTSignedIn: Bool
    var accounts: [Account]
    var accountReadings: [UUID: ProviderReading]
    var signedInAccounts: Set<UUID> = []
    /// What is wrong with an account's website, if anything.
    var accountErrors: [UUID: String] = [:]
    var launchAtLoginAvailable: Bool
    var launchesAtLogin: Bool
    var errors: [String]
    var now: Date
}

struct PanelActions {
    var refresh: () -> Void
    var toggleSettings: () -> Void
    var signInToClaude: () -> Void
    var signInToChatGPT: () -> Void
    var addAccount: (Provider) -> Void
    var setPinned: (UUID, Bool) -> Void
    var setMenuValue: (UUID, MenuBarValue) -> Void = { _, _ in }
    /// Reorder from the accounts list (SwiftUI `onMove` indices).
    var moveAccounts: (IndexSet, Int) -> Void = { _, _ in }
    var setMenuLabel: (UUID, MenuBarLabel) -> Void = { _, _ in }
    var renameAccount: (UUID, String) -> Void
    var removeAccount: (UUID) -> Void
    var signInAccount: (UUID) -> Void
    var signOutAccount: (UUID) -> Void = { _ in }
    var toggleLaunchAtLogin: (Bool) -> Void
    var quit: () -> Void
}

/// The popover: usage on the front, everything else behind the gear.
struct UsagePanel: View {
    let model: PanelModel
    let actions: PanelActions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            ScrollView {
                if model.showingSettings {
                    SettingsPage(model: model, actions: actions)
                } else {
                    usagePage
                }
            }
            .frame(maxHeight: 620)
        }
        .padding(14)
        .frame(width: 340)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(model.showingSettings ? "Settings" : "AI Usage Meter").font(.headline)
            Spacer()
            if model.isScanning {
                ProgressView().controlSize(.small)
            } else if !model.showingSettings {
                Button(action: actions.refresh) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Check now")
            }
            Button(action: actions.toggleSettings) {
                Image(systemName: model.showingSettings ? "chevron.backward" : "gearshape")
            }
            .buttonStyle(.borderless)
            .help(model.showingSettings ? "Back to usage" : "Settings")
        }
    }

    // MARK: Usage

    private var usagePage: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let report = model.report {
                if model.accounts.isEmpty {
                    if let codex = report.codex { ProviderCard(reading: codex, now: model.now) }
                    if let claude = report.claude { ProviderCard(reading: claude, now: model.now) }
                } else {
                    ForEach(model.accounts, id: \.id) { account in
                        if let problem = model.accountErrors[account.id] {
                            // Signed out or not answering: no number, which
                            // could be old, just what's wrong and the fix.
                            AccountProblemCard(account: account, problem: problem,
                                               signIn: { actions.signInAccount(account.id) })
                        } else if let reading = model.accountReadings[account.id] {
                            ProviderCard(reading: reading, now: model.now, accountLabel: account.label)
                        } else {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(account.label).font(.subheadline.weight(.semibold))
                                Text("Waiting for a usage reading").font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
                        }
                    }
                }

                // Anything needing attention is one short line with a way to fix
                // it; the details live in Settings.
                if !model.errors.isEmpty {
                    Button(action: actions.toggleSettings) {
                        HStack(spacing: 5) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text(model.errors.count == 1 ? "1 thing needs attention"
                                                         : "\(model.errors.count) things need attention")
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.link)
                    .foregroundStyle(.orange)
                }

                Text("Updated \(Fmt.age(report.scannedAt, now: model.now))")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading…").foregroundStyle(.secondary)
                }
                .padding(.vertical, 10)
            }
        }
    }
}

// MARK: - Settings

struct SettingsPage: View {
    let model: PanelModel
    let actions: PanelActions

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Accounts").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if model.accounts.isEmpty {
                    accountRow(name: "Claude", detail: "claude.ai · every minute",
                               signedIn: model.claudeSignedIn, signIn: actions.signInToClaude)
                    accountRow(name: "ChatGPT", detail: "chatgpt.com · every minute",
                               signedIn: model.chatGPTSignedIn, signIn: actions.signInToChatGPT)
                } else {
                    // A native list, so dragging a card slides the others aside
                    // and shows where it will land. The usage cards and menu bar
                    // items follow this order. A List has no height of its own
                    // inside the popover, so each row has a fixed height and the
                    // list is sized to fit them all.
                    List {
                        ForEach(model.accounts, id: \.id) { account in
                            AccountSettingsRow(account: account, signedIn: model.signedInAccounts.contains(account.id),
                                               actions: actions)
                                .frame(height: AccountSettingsRow.height(account), alignment: .top)
                                // The list's own ~16 pt side inset stays: row cells
                                // clip anything wider, cutting off the card edges.
                                .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0))
                                .listRowSeparator(.hidden)
                        }
                        .onMove { actions.moveAccounts($0, $1) }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .scrollDisabled(true)
                    .frame(height: model.accounts.map { AccountSettingsRow.height($0) + 6 }.reduce(0, +))
                }
                HStack {
                    Button("Add Claude account") { actions.addAccount(.claude) }
                    Button("Add Codex account") { actions.addAccount(.codex) }
                }
                .font(.caption)
                Text("Sign-in happens on the provider's own page, in a window this app owns. "
                     + "Use email: Google sign-in doesn't work in app windows.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Options").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if model.launchAtLoginAvailable {
                    Toggle(isOn: Binding(get: { model.launchesAtLogin },
                                         set: { actions.toggleLaunchAtLogin($0) })) {
                        Text("Open at login").font(.caption)
                    }
                    .toggleStyle(.checkbox)
                }
            }

            if !model.errors.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Needs attention").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(Array(model.errors.prefix(4).enumerated()), id: \.offset) { _, err in
                        Text(err).font(.caption2).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Divider()

            HStack(spacing: 5) {
                Circle().fill(model.isWatching ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
                Text(model.isWatching ? "Codex log backup active" : "Codex log backup unavailable")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Quit", action: actions.quit).buttonStyle(.borderless).font(.caption)
            }
        }
    }

    private func accountRow(name: String, detail: String,
                            signedIn: Bool, signIn: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.caption.weight(.medium))
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if signedIn {
                HStack(spacing: 3) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Signed in").font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Button("Sign in", action: signIn).font(.caption)
            }
        }
    }
}

private struct AccountSettingsRow: View {
    let account: Account
    let signedIn: Bool
    let actions: PanelActions

    /// Renaming happens in place: the name becomes a text field.
    @State private var renaming = false
    @State private var draftName = ""
    @FocusState private var nameFocused: Bool

    /// Fixed so the accounts list can be sized; pinned rows have the
    /// appearance menus as a third line.
    static func height(_ account: Account) -> CGFloat { account.pinned ? 92 : 64 }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.secondary)
                    .help("Drag to reorder")
                Text(account.provider == .claude ? "Claude" : "Codex")
                    .font(.caption.weight(.semibold))
                Spacer()
                Toggle("Pin", isOn: Binding(get: { account.pinned },
                                             set: { actions.setPinned(account.id, $0) }))
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
            HStack {
                if renaming {
                    TextField("Name", text: $draftName)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .focused($nameFocused)
                        .onSubmit(saveName)
                        .onExitCommand { renaming = false }
                    Button("Save", action: saveName)
                        .font(.caption)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Text(account.label)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Rename") {
                        draftName = account.label
                        renaming = true
                        nameFocused = true
                    }
                    .font(.caption)
                }
                if signedIn {
                    Button("Sign out", action: signOut)
                        .font(.caption)
                } else {
                    Button("Sign in") { actions.signInAccount(account.id) }
                        .font(.caption)
                }
                Button(role: .destructive, action: remove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove \(account.label)")
            }
            // How it looks in the menu bar; only matters while pinned.
            if account.pinned {
                HStack(spacing: 6) {
                    Picker("", selection: Binding(get: { account.labelStyle },
                                                  set: { actions.setMenuLabel(account.id, $0) })) {
                        ForEach(MenuBarLabel.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .help("What identifies this account in the menu bar")
                    Picker("", selection: Binding(get: { account.value },
                                                  set: { actions.setMenuValue(account.id, $0) })) {
                        ForEach(MenuBarValue.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .help("What this account shows in the menu bar")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .font(.caption)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Return or Save keeps the new name; Escape, or an empty name, keeps the old one.
    private func saveName() {
        let label = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = false
        if !label.isEmpty && label != account.label { actions.renameAccount(account.id, label) }
    }

    private func signOut() {
        let alert = NSAlert()
        alert.messageText = "Sign out of \(account.label)?"
        alert.informativeText = "The app stops checking this account's website until you sign in again."
        alert.addButton(withTitle: "Sign out")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        actions.signOutAccount(account.id)
    }

    private func remove() {
        let alert = NSAlert()
        alert.messageText = "Remove \(account.label)?"
        alert.informativeText = "You can add this account again later by signing in."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        actions.removeAccount(account.id)
    }
}

// MARK: - An account whose website isn't working

private struct AccountProblemCard: View {
    let account: Account
    let problem: String
    let signIn: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(account.label).font(.subheadline.weight(.semibold))
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Button("Sign in", action: signIn).font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
    }

    /// The stored message starts with the account's name, already shown above.
    private var message: String {
        let prefix = "\(account.label): "
        return problem.hasPrefix(prefix) ? String(problem.dropFirst(prefix.count)) : problem
    }
}

// MARK: - One provider's card

struct ProviderCard: View {
    let reading: ProviderReading
    let now: Date
    var accountLabel: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(accountLabel ?? reading.providerName).font(.subheadline.weight(.semibold))
                if let plan = planLabel {
                    Text(plan).font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
            }
            allowanceSection
        }
        .padding(10)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
    }

    /// Badge next to the provider name.
    ///
    /// Codex logs give an internal id (`prolite` = ChatGPT Pro 5x). Claude's data
    /// has no plan at all, so its badge is an optional setting, hidden when unset:
    ///
    ///     defaults write io.github.prajwalsr.aiusagemeter claudePlanLabel "Pro"
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
    /// includes the provider's own limit id when it isn't the usual one.
    private func limitName(_ w: AllowanceWindow) -> String {
        switch reading.provider {
        case .claude:
            return "\(w.windowLabel) limit"
        case .codex:
            if let id = w.limitId, !["codex", "primary", "secondary"].contains(id) {
                return "\(w.windowLabel) Codex limit (\(id))"
            }
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
                bar(head.usedPercent)
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
                        bar(w.usedPercent)
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

    private func bar(_ percent: Double) -> some View {
        ProgressView(value: min(percent, 100), total: 100).tint(tint(percent))
    }

    /// What happens next depends on where the reading came from.
    private func expiredExplanation(_ source: ReadingSource) -> String {
        let base = "The last reading's limit has reset since it was taken, so the current "
                 + "figure isn't known yet. "
        switch source {
        case .codexLog: return base + "It updates the next time Codex runs."
        case .claudeStatusLine: return base + "It updates the next time Claude Code runs in a terminal."
        case .claudeWeb: return base + "It updates at the next check with claude.ai."
        case .chatgptWeb: return base + "It updates at the next check with chatgpt.com."
        }
    }

    /// Same bands as the menu bar, so both always agree. Below 25% the figure
    /// uses the ordinary text colour (the accent colour is nearly invisible on
    /// this card in some themes).
    private func tint(_ pct: Double) -> Color {
        let band = ProviderIcons.UsageBand(usedPercent: pct.rounded())
        return band == .plain ? .primary : Color(nsColor: band.color)
    }
}
