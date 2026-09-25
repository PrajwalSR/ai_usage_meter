import AppKit
import Foundation
import ServiceManagement

/// App state on the main actor: runs index passes in the background, owns the
/// file watcher and timers, and polls the provider websites.
///
/// Uses a plain `onChange` callback instead of SwiftUI's `@Observable`/`@State`,
/// because those macros didn't build with Command Line Tools alone (see
/// CONTRIBUTING.md → "Why not Xcode or swift build?").
@MainActor
final class UsageStore {
    private(set) var report: UsageReport?
    private(set) var isScanning = false
    private(set) var isWatching = false
    private(set) var indexError: String?

    var onChange: (() -> Void)?

    /// The panel shows usage on the front and everything else behind the gear.
    private(set) var showingSettings = false
    func toggleSettings() {
        showingSettings.toggle()
        onChange?()
    }

    /// Everything worth telling the user about, newest concern first. Shown as a
    /// single line on the usage page and in full in Settings.
    var attentionItems: [String] {
        var items: [String] = []
        if let indexError { items.append(indexError) }
        items.append(contentsOf: webErrors.values.sorted())
        if let report { items.append(contentsOf: report.errors) }
        return items
    }

    private var index: UsageIndex?
    private var watcher: FileWatcher?
    private var redrawTimer: Timer?
    private var webTimer: Timer?
    /// A pass requested while one is running becomes one follow-up pass.
    private var rescanQueued = false

    // MARK: Lifecycle

    init() {
        // Remove the request cache earlier builds left behind (it held the login
        // header). Only reports a problem if removal fails.
        indexError = LegacyCleanup.removeLegacyURLCache()
        LegacyCleanup.removeLegacyLiveReading()

        do {
            index = try UsageIndex()
        } catch {
            indexError = "Could not open the local cache: \(error)"
        }

        // Redraw only: keeps "3m ago", countdowns and expiry current. Expiry is
        // computed while drawing, so a reset shows up here without a rescan.
        redrawTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.onChange?() }
        }

        try? FileManager.default.createDirectory(at: ClaudeReadings.directory,
                                                 withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        // Claude Code's logs are deliberately not watched: the app doesn't count
        // tokens, so it never reads your conversations.
        watcher = FileWatcher(paths: [CodexParser.root.path,
                                      ClaudeReadings.directory.path]) { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        isWatching = watcher?.isWatching ?? false

        scheduleWebChecks()
        fetchAllWebUsage()

        // FSEvents can miss changes while the Mac sleeps.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    // MARK: Provider websites (signed-in web views)

    /// One website source: how to ask it, where to put the answer, and what went
    /// wrong last time.
    struct WebProvider {
        let account: Account
        let session: WebSession
        let destination: WebUsageSource.Destination
        let source: ReadingSource
        let readingURL: URL

        @MainActor static var claude: WebProvider {
            forAccount(AccountRegistry.shared.accounts.first { $0.provider == .claude }!)
        }
        @MainActor static var chatGPT: WebProvider {
            forAccount(AccountRegistry.shared.accounts.first { $0.provider == .codex }!)
        }
        @MainActor static func forAccount(_ account: Account) -> WebProvider {
            let legacy = AccountRegistry.isLegacy(account)
            let source: ReadingSource = account.provider == .claude ? .claudeWeb : .chatgptWeb
            let stem = "\(account.provider.rawValue)-\(account.id.uuidString)"
            let reading = legacy
                ? (account.provider == .claude ? ClaudeReadings.webFileURL : CodexReadings.webFileURL)
                : ClaudeReadings.directory.appendingPathComponent("\(stem).json")
            let raw = ClaudeReadings.directory.appendingPathComponent("\(stem)-raw.json")
            return WebProvider(account: account, session: .forAccount(account),
                               destination: .init(reading: reading, rawDump: raw),
                               source: source, readingURL: reading)
        }
    }

    private(set) var webErrors: [UUID: String] = [:]
    private var webFetchesInFlight: Set<UUID> = []
    var accounts: [Account] { AccountRegistry.shared.accounts }

    /// Whether a usable reading from that website exists.
    func isSignedIn(_ provider: WebProvider) -> Bool {
        FileManager.default.fileExists(atPath: provider.readingURL.path)
            && webErrors[provider.account.id] == nil
    }

    var claudeSignedIn: Bool { isSignedIn(.claude) }
    var chatGPTSignedIn: Bool { isSignedIn(.chatGPT) }

    /// Whether the user has asked for this website at all. Until they click
    /// Sign in, the site is never loaded: nothing goes online unasked, and
    /// someone relying on Codex's logs alone isn't nagged with "Not signed in".
    /// A reading already on disk counts, so earlier installs keep working.
    func isEnabled(_ provider: WebProvider) -> Bool {
        UserDefaults.standard.bool(forKey: Self.enabledKey(provider))
            || FileManager.default.fileExists(atPath: provider.readingURL.path)
    }

    private static func enabledKey(_ provider: WebProvider) -> String {
        AccountRegistry.isLegacy(provider.account)
            ? "webUsageEnabled.\(provider.source.rawValue)"
            : "webUsageEnabled.\(provider.account.id.uuidString)"
    }

    /// Opens that provider's own sign-in page in a window this app owns.
    func signIn(to provider: WebProvider) {
        UserDefaults.standard.set(true, forKey: Self.enabledKey(provider))
        provider.session.showLoginWindow()
        // Give the sign-in a moment, then start checking.
        Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.fetchWebUsage(provider) }
        }
    }

    func addAccount(_ provider: Provider) {
        let number = accounts.filter { $0.provider == provider }.count + 1
        let account = AccountRegistry.shared.add(provider: provider,
            label: "\(provider.displayName) \(number)", pinned: false)
        onChange?()
        signIn(to: .forAccount(account))
    }

    func signInAccount(_ id: UUID) {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        signIn(to: .forAccount(account))
    }

    func setPinned(_ id: UUID, _ pinned: Bool) {
        guard var account = accounts.first(where: { $0.id == id }) else { return }
        account.pinned = pinned
        AccountRegistry.shared.update(account)
        onChange?()
    }

    func moveAccounts(fromOffsets source: IndexSet, toOffset destination: Int) {
        AccountRegistry.shared.move(fromOffsets: source, toOffset: destination)
        onChange?()
    }

    func setMenuValue(_ id: UUID, _ value: MenuBarValue) {
        guard var account = accounts.first(where: { $0.id == id }) else { return }
        account.menuValue = value
        AccountRegistry.shared.update(account)
        onChange?()
    }

    func setMenuLabel(_ id: UUID, _ label: MenuBarLabel) {
        guard var account = accounts.first(where: { $0.id == id }) else { return }
        account.menuLabel = label
        AccountRegistry.shared.update(account)
        onChange?()
    }

    func renameAccount(_ id: UUID, _ label: String) {
        guard var account = accounts.first(where: { $0.id == id }) else { return }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        account.label = trimmed
        AccountRegistry.shared.update(account)
        onChange?()
    }

    func removeAccount(_ id: UUID) {
        guard let account = accounts.first(where: { $0.id == id }),
              !AccountRegistry.isLegacy(account) else { return }
        let provider = WebProvider.forAccount(account)
        AccountRegistry.shared.remove(id: id)
        UserDefaults.standard.removeObject(forKey: Self.enabledKey(provider))
        webErrors.removeValue(forKey: id)
        try? FileManager.default.removeItem(at: provider.readingURL)
        try? FileManager.default.removeItem(at: provider.destination.rawDump)
        WebSession.removeAccountData(account) { [weak self] error in
            if let error {
                self?.indexError = "Could not clear \(account.label)'s sign-in: \(error.localizedDescription)"
                self?.onChange?()
            }
        }
        onChange?()
    }

    var accountReadings: [UUID: ProviderReading] {
        var result: [UUID: ProviderReading] = [:]
        for account in accounts {
            let provider = WebProvider.forAccount(account)
            let reading = ClaudeReadings.read(provider.readingURL, source: provider.source)
            if AccountRegistry.isLegacy(account), reading == nil {
                if let fallback = account.provider == .claude ? report?.claude : report?.codex {
                    result[account.id] = fallback
                    continue
                }
            }
            result[account.id] = ProviderReading(provider: account.provider,
                readings: reading.map { [$0] } ?? [],
                unavailableNote: "Sign in to see this account’s usage.")
        }
        return result
    }

    private func scheduleWebChecks() {
        webTimer?.invalidate()
        webTimer = Timer.scheduledTimer(withTimeInterval: WebUsageSource.pollInterval,
                                        repeats: true) { [weak self] _ in
            Task { @MainActor in self?.fetchAllWebUsage() }
        }
    }

    /// Asks every website the user has signed in to (see `isEnabled`).
    func fetchAllWebUsage() {
        for account in accounts {
            let provider = WebProvider.forAccount(account)
            guard isEnabled(provider) else { continue }
            fetchWebUsage(provider)
        }
    }

    /// Asks a provider's website from inside its signed-in page. Cheap enough to
    /// run every minute.
    func fetchWebUsage(_ provider: WebProvider) {
        guard !webFetchesInFlight.contains(provider.account.id) else { return }
        webFetchesInFlight.insert(provider.account.id)
        provider.session.fetchRawUsage { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.webFetchesInFlight.remove(provider.account.id)
                guard self.accounts.contains(where: { $0.id == provider.account.id }) else { return }
                switch result {
                case .success(let json):
                    let problem = WebUsageSource.store(rawJSON: json, to: provider.destination,
                                                       source: provider.source)
                    self.webErrors[provider.account.id] = problem
                    provider.session.closeLoginWindow()
                    self.refresh()
                case .failure(let failure):
                    self.webErrors[provider.account.id] = "\(provider.account.label): \(failure.description)"
                    self.onChange?()
                }
            }
        }
    }

    // MARK: Refreshing

    /// Refresh button: asks the websites again, then rescans.
    func refreshAll() {
        fetchAllWebUsage()
        refresh()
    }

    func refresh() {
        guard let index else { return }
        guard !isScanning else { rescanQueued = true; return }
        isScanning = true
        onChange?()

        Task {
            let result = await Task.detached(priority: .utility) { index.refresh() }.value
            self.report = result
            self.isScanning = false
            self.onChange?()
            if self.rescanQueued {
                self.rescanQueued = false
                self.refresh()
            }
        }
    }

    // MARK: Launch at login

    /// Only meaningful for the bundled .app; a bare binary has nothing to register.
    var launchAtLoginAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    var launchesAtLogin: Bool {
        launchAtLoginAvailable && SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ on: Bool) {
        guard launchAtLoginAvailable else { return }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            indexError = "Open at login failed: \(error.localizedDescription)"
        }
        onChange?()
    }

    // MARK: Menu bar

    var menuBarImage: NSImage {
        let now = Date()
        let readings = accountReadings
        let figures: [(Provider, ProviderIcons.MenuBarFigure)] = accounts
            .filter(\.pinned).compactMap { account in
                guard let reading = readings[account.id] else { return nil }
                var figure = Self.menuBarFigure(reading, now: now, value: account.value)
                figure.name = account.labelStyle.showsName ? account.label : nil
                figure.showsLogo = account.labelStyle.showsLogo
                return (account.provider, figure)
            }
        return ProviderIcons.menuBarImage(figures)
    }

    /// Text plus the percentages that colour it, rounded like the text so the
    /// colour matches the number shown. No percentage (so no colour) once the
    /// reading has reset or when there is none.
    nonisolated static func menuBarFigure(_ r: ProviderReading, now: Date,
                                          value: MenuBarValue = .percentAndTime) -> ProviderIcons.MenuBarFigure {
        guard case .available(let head, let others, _) = r.display(now: now) else {
            return ProviderIcons.MenuBarFigure(text: menuBarText(r, now: now))
        }
        let pct = { (w: AllowanceWindow) in "\(Int(w.usedPercent.rounded()))%" }
        let used = head.usedPercent.rounded()
        switch value {
        case .percentAndTime:
            return ProviderIcons.MenuBarFigure(text: menuBarText(r, now: now), usedPercent: used)
        case .percent:
            return ProviderIcons.MenuBarFigure(text: pct(head), usedPercent: used)
        case .timeLeft:
            // With no reset time there is no countdown; the percentage is the
            // only honest thing to show.
            guard let resets = head.resetsAt else {
                return ProviderIcons.MenuBarFigure(text: pct(head), usedPercent: used)
            }
            return ProviderIcons.MenuBarFigure(text: Fmt.countdown(to: resets, now: now), usedPercent: used)
        case .allLimits:
            // Whatever limits the account reports right now, shortest window
            // first: "38% · 63%" for 5-hour + weekly, "63%" for weekly only.
            let windows = ([head] + others).sorted { ($0.windowMinutes ?? .max) < ($1.windowMinutes ?? .max) }
            let percents = windows.map { $0.usedPercent.rounded() }
            return ProviderIcons.MenuBarFigure(text: windows.map(pct).joined(separator: " · "),
                                               usedPercent: percents.first,
                                               morePercents: Array(percents.dropFirst()))
        }
    }

    /// "38% in 2h 21m" for a valid reading, "?" once it has reset (unknown, not
    /// zero), "—" when there is no reading. Expiry is checked against `now` on
    /// every redraw.
    nonisolated static func menuBarText(_ r: ProviderReading, now: Date) -> String {
        switch r.display(now: now) {
        case .available(let head, _, _):
            let pct = "\(Int(head.usedPercent.rounded()))%"
            guard let resets = head.resetsAt else { return pct }
            return "\(pct) in \(Fmt.countdown(to: resets, now: now))"
        case .expired: return "?"
        case .unavailable: return "—"
        }
    }
}
