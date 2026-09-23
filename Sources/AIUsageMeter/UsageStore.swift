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
        let session: WebSession
        let destination: WebUsageSource.Destination
        let source: ReadingSource
        let readingURL: URL

        @MainActor static var claude: WebProvider {
            WebProvider(session: .claude, destination: .claude,
                        source: .claudeWeb, readingURL: ClaudeReadings.webFileURL)
        }
        @MainActor static var chatGPT: WebProvider {
            WebProvider(session: .chatGPT, destination: .chatGPT,
                        source: .chatgptWeb, readingURL: CodexReadings.webFileURL)
        }
    }

    private(set) var webErrors: [ReadingSource: String] = [:]
    private var webFetchesInFlight: Set<ReadingSource> = []

    /// Whether a usable reading from that website exists.
    func isSignedIn(_ provider: WebProvider) -> Bool {
        FileManager.default.fileExists(atPath: provider.readingURL.path)
            && webErrors[provider.source] == nil
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
        "webUsageEnabled.\(provider.source.rawValue)"
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

    private func scheduleWebChecks() {
        webTimer?.invalidate()
        webTimer = Timer.scheduledTimer(withTimeInterval: WebUsageSource.pollInterval,
                                        repeats: true) { [weak self] _ in
            Task { @MainActor in self?.fetchAllWebUsage() }
        }
    }

    /// Asks every website the user has signed in to (see `isEnabled`).
    func fetchAllWebUsage() {
        for provider in [WebProvider.claude, .chatGPT] where isEnabled(provider) {
            fetchWebUsage(provider)
        }
    }

    /// Asks a provider's website from inside its signed-in page. Cheap enough to
    /// run every minute.
    func fetchWebUsage(_ provider: WebProvider) {
        guard !webFetchesInFlight.contains(provider.source) else { return }
        webFetchesInFlight.insert(provider.source)
        provider.session.fetchRawUsage { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.webFetchesInFlight.remove(provider.source)
                switch result {
                case .success(let json):
                    let problem = WebUsageSource.store(rawJSON: json, to: provider.destination,
                                                       source: provider.source)
                    self.webErrors[provider.source] = problem
                    provider.session.closeLoginWindow()
                    self.refresh()
                case .failure(let failure):
                    self.webErrors[provider.source] = "\(provider.session.siteName): \(failure.description)"
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
        return ProviderIcons.menuBarImage(
            codex: report?.codex.map { Self.menuBarFigure($0, now: now) },
            claude: report?.claude.map { Self.menuBarFigure($0, now: now) })
    }

    /// Text plus the percentage that colours it, rounded like the text so the
    /// colour matches the number shown. No percentage (so no colour) once the
    /// reading has reset or when there is none.
    nonisolated static func menuBarFigure(_ r: ProviderReading, now: Date) -> ProviderIcons.MenuBarFigure {
        var used: Double?
        if case .available(let head, _, _) = r.display(now: now) { used = head.usedPercent.rounded() }
        return ProviderIcons.MenuBarFigure(text: menuBarText(r, now: now), usedPercent: used)
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
