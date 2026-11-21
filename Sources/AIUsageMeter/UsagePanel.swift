import SwiftUI
import AppKit

/// Everything the panel needs, passed in as plain values. No SwiftUI state
/// macros (they didn't build with Command Line Tools alone), and `now` is passed
/// in so expiry and "… ago" text are recomputed on every redraw.
struct PanelModel {
    var report: UsageReport?
    var isScanning: Bool
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
    /// The account whose options start open (used for screenshots).
    var initiallyExpanded: UUID? = nil
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
                Group {
                    if model.showingSettings {
                        SettingsPage(model: model, actions: actions)
                    } else {
                        usagePage
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: 620)
        }
        .padding(14)
        .frame(width: 340)
        // While a row opens, the window is already its new height and the
        // content is still growing. Centred, everything would drift; pinned to
        // the top, only the space below the opening row moves.
        .frame(maxHeight: .infinity, alignment: .top)
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

    /// The one account whose options are open, if any.
    @State private var expanded: UUID?
    /// The account being renamed, and its new name so far.
    @State private var renaming: UUID?
    @State private var draftName = ""
    @FocusState private var nameFocused: Bool

    /// The account being dragged to a new place, if any.
    @State private var dragging: UUID?

    init(model: PanelModel, actions: PanelActions) {
        self.model = model
        self.actions = actions
        _expanded = State(initialValue: model.initiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Accounts").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        Button("Claude account") { actions.addAccount(.claude) }
                        Button("Codex account") { actions.addAccount(.codex) }
                    } label: {
                        Label("Add account", systemImage: "plus").font(.caption)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .controlSize(.small)
                    .fixedSize()
                    .help("Sign in to another Claude or Codex account")
                }
                if model.accounts.isEmpty {
                    accountRow(name: "Claude", detail: "claude.ai · every minute",
                               signedIn: model.claudeSignedIn, signIn: actions.signInToClaude)
                    accountRow(name: "ChatGPT", detail: "chatgpt.com · every minute",
                               signedIn: model.chatGPTSignedIn, signIn: actions.signInToChatGPT)
                } else {
                    // Plain SwiftUI rows, not a native List: inserting a row
                    // into a List flashed the gap black while it slid the rows
                    // below. The usage cards and menu bar items follow this order.
                    VStack(spacing: 0) {
                        ForEach(model.accounts, id: \.id) { account in
                            VStack(spacing: 0) {
                                AccountSummaryRow(
                                    account: account,
                                    reading: model.accountReadings[account.id],
                                    hasProblem: model.accountErrors[account.id] != nil,
                                    isExpanded: expanded == account.id,
                                    isRenaming: renaming == account.id,
                                    draftName: $draftName,
                                    nameFocused: $nameFocused,
                                    now: model.now,
                                    toggle: { toggle(account.id) },
                                    saveName: { saveName(account) },
                                    cancelRename: { renaming = nil },
                                    setPinned: { actions.setPinned(account.id, $0) })
                                    .frame(height: AccountSummaryRow.height)
                                    // Dragged by the account's own row, so the
                                    // controls in an open row still work.
                                    .onDrag {
                                        expanded = nil
                                        dragging = account.id
                                        return NSItemProvider(object: account.id.uuidString as NSString)
                                    }
                                if expanded == account.id {
                                    AccountDetailsRow(
                                        account: account,
                                        signedIn: model.signedInAccounts.contains(account.id),
                                        isRenaming: renaming == account.id,
                                        startRename: { startRename(account) },
                                        saveName: { saveName(account) },
                                        cancelRename: { renaming = nil },
                                        actions: actions)
                                        .frame(height: AccountDetailsRow.height)
                                        .transition(.opacity)
                                }
                            }
                            .onDrop(of: [.text], delegate: AccountDropDelegate(
                                target: account.id, accounts: model.accounts,
                                dragging: $dragging, move: actions.moveAccounts))
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                Text("You sign in on the provider's own page. If Google refuses, use email.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.launchAtLoginAvailable {
                Divider()
                Toggle(isOn: Binding(get: { model.launchesAtLogin },
                                     set: { actions.toggleLaunchAtLogin($0) })) {
                    Text("Open at login").font(.callout)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
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

            HStack {
                Spacer()
                Button("Quit", action: actions.quit).buttonStyle(.borderless).font(.caption)
            }
        }
    }

    private func toggle(_ id: UUID) {
        withAnimation(.easeInOut(duration: 0.22)) { expanded = expanded == id ? nil : id }
    }

    private func startRename(_ account: Account) {
        draftName = account.label
        renaming = account.id
        nameFocused = true
    }

    /// Return or Save keeps the new name; Escape, or an empty name, keeps the old one.
    private func saveName(_ account: Account) {
        let label = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = nil
        if !label.isEmpty && label != account.label { actions.renameAccount(account.id, label) }
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

/// Reorders as you drag: hovering over another account moves the dragged one
/// into its place, and the rows slide to make room.
private struct AccountDropDelegate: DropDelegate {
    let target: UUID
    let accounts: [Account]
    @Binding var dragging: UUID?
    let move: (IndexSet, Int) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragged = dragging, dragged != target,
              let from = accounts.firstIndex(where: { $0.id == dragged }),
              let to = accounts.firstIndex(where: { $0.id == target }) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            move(IndexSet(integer: from), to > from ? to + 1 : to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

/// One account's row: logo, name, plan, and what it shows in the menu bar.
/// Its height never changes; opening it adds `AccountDetailsRow` below.
private struct AccountSummaryRow: View {
    let account: Account
    let reading: ProviderReading?
    let hasProblem: Bool
    let isExpanded: Bool
    let isRenaming: Bool
    @Binding var draftName: String
    var nameFocused: FocusState<Bool>.Binding
    let now: Date
    let toggle: () -> Void
    let saveName: () -> Void
    let cancelRename: () -> Void
    let setPinned: (Bool) -> Void

    static let height: CGFloat = 48

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.caption).foregroundStyle(.tertiary)
                .help("Drag to reorder")
            Image(nsImage: account.provider == .claude ? ProviderIcons.claude : ProviderIcons.codex)
                .foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if isRenaming {
                        TextField("Name", text: $draftName)
                            .textFieldStyle(.roundedBorder)
                            .font(.callout)
                            .focused(nameFocused)
                            .onSubmit(saveName)
                            .onExitCommand(perform: cancelRename)
                    } else {
                        Text(account.label).font(.callout.weight(.medium))
                            .lineLimit(1).truncationMode(.middle)
                            .layoutPriority(1)
                        if let plan = reading.flatMap(ProviderCard.planLabel) {
                            Text(plan).font(.caption2)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                }
                preview
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            Button { setPinned(!account.pinned) } label: {
                Image(systemName: account.pinned ? "pin.fill" : "pin")
                    .foregroundStyle(account.pinned ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.borderless)
            .help(account.pinned ? "Shown in the menu bar. Click to hide." : "Hidden. Click to show in the menu bar.")
            Image(systemName: "chevron.down")
                .font(.caption).foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { if !isRenaming { toggle() } }
        .overlay(alignment: .bottom) {
            if !isExpanded { Rectangle().fill(Color.secondary.opacity(0.15)).frame(height: 0.5) }
        }
    }

    /// Exactly what this account shows in the menu bar right now, drawn the
    /// same way, or a note when it isn't shown there.
    @ViewBuilder private var preview: some View {
        if !account.pinned {
            Text("Not in menu bar").font(.caption).foregroundStyle(.secondary)
        } else if let image = menuBarPreview {
            Image(nsImage: image)
                .opacity(0.75)
                .help("How it looks in the menu bar")
        } else {
            Text("Waiting for a reading").font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Drawn by the same code as the menu bar item, so it can't drift from it.
    private var menuBarPreview: NSImage? {
        guard let reading else { return nil }
        var figure = hasProblem ? ProviderIcons.MenuBarFigure(text: "⚠︎")
            : UsageStore.menuBarFigure(reading, now: now, value: account.value)
        figure.name = account.labelStyle.showsName ? account.label : nil
        figure.showsLogo = account.labelStyle.showsLogo
        return ProviderIcons.menuBarImage([(account.provider, figure)])
    }
}

/// The opened part under an account: its menu bar options and actions.
private struct AccountDetailsRow: View {
    let account: Account
    let signedIn: Bool
    let isRenaming: Bool
    let startRename: () -> Void
    let saveName: () -> Void
    let cancelRename: () -> Void
    let actions: PanelActions

    static let height: CGFloat = 92

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("Show").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: Binding(get: { account.labelStyle },
                                                  set: { actions.setMenuLabel(account.id, $0) })) {
                        Text("Logo").tag(MenuBarLabel.logo)
                        Text("Name").tag(MenuBarLabel.name)
                        Text("Both").tag(MenuBarLabel.logoAndName)
                        Text("None").tag(MenuBarLabel.none)
                    }
                    .pickerStyle(.segmented)
                    .help("What identifies this account in the menu bar")
                }
                GridRow {
                    Text("Value").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: Binding(get: { account.value },
                                                  set: { actions.setMenuValue(account.id, $0) })) {
                        ForEach(MenuBarValue.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .help("What this account shows in the menu bar")
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .disabled(!account.pinned)

            HStack(spacing: 14) {
                if isRenaming {
                    Button("Save", action: saveName).keyboardShortcut(.defaultAction)
                    Button("Cancel", action: cancelRename)
                } else {
                    Button("Rename", action: startRename)
                }
                if signedIn {
                    Button("Sign out", action: signOut)
                } else {
                    Button("Sign in") { actions.signInAccount(account.id) }
                }
                Spacer()
                Button("Remove", role: .destructive, action: remove)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(.leading, 40).padding(.trailing, 10).padding(.top, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.secondary.opacity(0.15)).frame(height: 0.5)
        }
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
    /// chatgpt.com gives an internal id (`prolite` = ChatGPT Pro 5x). claude.ai
    /// names the plan on the signed-in organization. Claude's status line has
    /// no plan, so a fixed label can be set for that case only; the website's
    /// plan always wins over it:
    ///
    ///     defaults write io.github.prajwalsr.aiusagemeter claudePlanLabel "Max"
    private var planLabel: String? { Self.planLabel(for: reading) }

    static func planLabel(for reading: ProviderReading) -> String? {
        if reading.provider == .claude {
            switch reading.planType {
            case "claude_max_20x": return "Max 20x"
            case "claude_max_5x": return "Max 5x"
            case "claude_max": return "Max"
            case "claude_pro": return "Pro"
            case "claude_team": return "Team"
            case "claude_enterprise": return "Enterprise"
            default:
                // A signed-in account whose plan is unknown (Free, or a new
                // plan) shows no badge rather than another account's label.
                guard !reading.readings.contains(where: { $0.source == .claudeWeb }) else { return nil }
                let label = UserDefaults.standard.string(forKey: "claudePlanLabel")
                return (label?.isEmpty ?? true) ? nil : label
            }
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
                return "\(w.windowLabel) \(rowLabel(w)) limit"
            }
            return "\(w.windowLabel) Codex limit"
        }
    }

    /// "1-Week" for the plan's own windows. A Claude limit with its own name
    /// (a model's weekly limit, "Fable") is called by that name instead, or it
    /// would read as a second "1-Week".
    private func rowLabel(_ w: AllowanceWindow) -> String {
        guard let id = w.limitId, !id.isEmpty else { return w.windowLabel.capitalized }
        switch reading.provider {
        case .claude:
            return id
        case .codex:
            // chatgpt.com's own names: the plan's limits are "codex" or a rank;
            // anything else is a separate limit and is called by its name.
            if ["codex", "primary", "secondary"].contains(id) { return w.windowLabel.capitalized }
            if id.contains("code_review") { return "Code review" }
            return Self.readable(id)
        }
    }

    /// "codex_other" → "Codex other".
    static func readable(_ id: String) -> String {
        let words = id.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// Information only: the reset is used on the provider's site, never here.
    /// Every reset's expiry, then where to use one.
    private func resetHover(_ r: AllowanceReading) -> String {
        let site = reading.provider == .codex ? "chatgpt.com" : "claude.ai"
        let dates = r.resetsExpireAll.filter { $0 > now }.map(Fmt.day)
        let note = "Use one on \(site) when you need it. This app only shows them."
        guard !dates.isEmpty else { return note }
        return "Expires " + dates.joined(separator: " · ") + "\n" + note
    }

    private func resetLine(_ r: AllowanceReading) -> String? {
        guard let count = r.resetsAvailable, count > 0 else { return nil }
        let what = count == 1 ? "1 limit reset available" : "\(count) limit resets available"
        guard let expiry = r.resetsExpireAt, expiry > now else { return what }
        return what + (count == 1 ? " · expires " : " · next expires ") + Fmt.day(expiry)
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
                        Text(rowLabel(w))
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(minWidth: 44, alignment: .leading)
                        bar(w.usedPercent)
                        Text("\(Int(w.usedPercent.rounded()))%")
                            .font(.caption.monospacedDigit())
                        if let r = w.resetsAt {
                            Text(Fmt.until(r, now: now)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                if let line = resetLine(source) {
                    Label(line, systemImage: "arrow.counterclockwise")
                        .font(.caption2).foregroundStyle(.secondary)
                        .help(resetHover(source))
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
