import AppKit
import Foundation
import ServiceManagement

/// App state on the main actor: runs index passes in the background, owns the
/// file watcher and timers, and schedules live Claude checks.
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
    /// Why the last live Claude check failed, if it did.
    private(set) var liveClaudeError: String?

    var onChange: (() -> Void)?

    private var index: UsageIndex?
    private var watcher: FileWatcher?
    private var redrawTimer: Timer?
    private var liveTimer: Timer?
    private var liveFetchInFlight = false
    /// Set when the user declines Keychain access. Automatic checks stop until
    /// they press refresh or turn the setting off and on, so macOS doesn't
    /// prompt every five minutes.
    private var livePausedByDecline = false
    /// Set when Anthropic refuses with HTTP 429. Automatic checks wait until this
    /// time; asking again sooner only earns more refusals.
    private var liveRetryAfter: Date?
    private var consecutiveRateLimits = 0
    /// When the last live check was attempted, to keep requests rare.
    private var lastLiveAttempt: Date?
    private var webTimer: Timer?
    private var webFetchInFlight = false
    /// Set when claude.ai says we're signed out, so the panel can offer sign-in.
    private(set) var webSignInNeeded = false
    private(set) var webError: String?
    /// A pass requested while one is running becomes one follow-up pass.
    private var rescanQueued = false

    // MARK: Settings

    private static let liveClaudeKey = "liveClaudeEnabled"

    /// "Check Claude usage live". Off by default: it reads the Claude Code login
    /// from the Keychain and contacts Anthropic, so the user opts in.
    var liveClaudeEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.liveClaudeKey)
    }

    func setLiveClaudeEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.liveClaudeKey)
        livePausedByDecline = false
        liveRetryAfter = nil
        consecutiveRateLimits = 0
        liveClaudeError = nil
        scheduleLiveChecks()
        if on { fetchLiveClaude() }
        onChange?()
    }

    // MARK: Lifecycle

    init() {
        // Remove the request cache earlier builds left behind (it held the login
        // header). Only reports a problem if removal fails.
        indexError = LegacyCleanup.removeLegacyURLCache()

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
        fetchWebUsage()

        scheduleLiveChecks()
        // Don't spend a request at every launch: quitting and reopening (or a
        // rebuild) shouldn't burn the rate-limit budget when the number on disk
        // is still fresh.
        if liveClaudeEnabled {
            let newestLive = ClaudeReadings.load()
                .filter { $0.source == .anthropicLive }
                .map(\.recordedAt).max()
            let age = newestLive.map { Date().timeIntervalSince($0) } ?? .infinity
            if age >= ClaudeLiveUsage.minimumInterval { fetchLiveClaude() }
        }

        // FSEvents can miss changes while the Mac sleeps.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    // MARK: claude.ai (signed-in web view)

    /// Whether a usable claude.ai reading exists. Drives the panel's button.
    var webSignedIn: Bool {
        !webSignInNeeded && FileManager.default.fileExists(atPath: ClaudeReadings.webFileURL.path)
    }

    /// Opens Anthropic's own sign-in page in a window this app owns.
    func signInToClaudeWeb() {
        ClaudeWebSession.shared.showLoginWindow()
        // Give the sign-in a moment, then start checking.
        Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.fetchWebUsage() }
        }
    }

    private func scheduleWebChecks() {
        webTimer?.invalidate()
        webTimer = Timer.scheduledTimer(withTimeInterval: ClaudeWebSource.pollInterval,
                                        repeats: true) { [weak self] _ in
            Task { @MainActor in self?.fetchWebUsage() }
        }
    }

    /// Asks claude.ai, from inside the signed-in page. Cheap enough to run every
    /// minute, unlike the api.anthropic.com route.
    func fetchWebUsage() {
        guard !webFetchInFlight else { return }
        webFetchInFlight = true
        ClaudeWebSession.shared.fetchRawUsage { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.webFetchInFlight = false
                switch result {
                case .success(let json):
                    self.webSignInNeeded = false
                    self.webError = ClaudeWebSource.store(rawJSON: json)
                    // A good claude.ai reading makes any backup-check complaint
                    // irrelevant (e.g. "Claude login expired").
                    if self.webError == nil { self.liveClaudeError = nil }
                    ClaudeWebSession.shared.closeLoginWindow()
                    self.refresh()
                case .failure(let failure):
                    if case .notSignedIn = failure { self.webSignInNeeded = true }
                    self.webError = failure.description
                    self.onChange?()
                }
            }
        }
    }

    // MARK: Refreshing

    /// Refresh button: clears any pause or wait and tries again, then rescans.
    func refreshAll() {
        fetchWebUsage()
        livePausedByDecline = false
        liveRetryAfter = nil
        consecutiveRateLimits = 0
        if liveClaudeEnabled { fetchLiveClaude() } else { refresh() }
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

    private func scheduleLiveChecks() {
        liveTimer?.invalidate()
        liveTimer = nil
        guard liveClaudeEnabled else { return }
        liveTimer = Timer.scheduledTimer(withTimeInterval: ClaudeLiveUsage.pollInterval,
                                         repeats: true) { [weak self] _ in
            Task { @MainActor in self?.maybeFetchLive() }
        }
    }

    /// Checks only if it has been a while, so background triggers can't flood
    /// Anthropic. `force` is for the refresh button, which the user pressed.
    func maybeFetchLive(force: Bool = false) {
        if !force, let lastLiveAttempt,
           Date().timeIntervalSince(lastLiveAttempt) < ClaudeLiveUsage.minimumInterval { return }
        fetchLiveClaude()
    }

    /// Called when the panel opens: a good moment for a fresh number, and it only
    /// happens when the user is actually looking.
    func panelOpened() {
        maybeFetchLive()
    }

    /// True when claude.ai gave us a reading recently enough that the backup
    /// check has nothing to add.
    private var webReadingIsFresh: Bool {
        guard let web = ClaudeReadings.load().filter({ $0.source == .claudeWeb })
            .max(by: { $0.recordedAt < $1.recordedAt }) else { return false }
        return Date().timeIntervalSince(web.recordedAt) <= ClaudeReadings.liveFreshness
    }

    private func fetchLiveClaude() {
        guard liveClaudeEnabled, !livePausedByDecline, !liveFetchInFlight else { return }
        // claude.ai is already answering: don't spend a rate-limited request, and
        // don't report its problems -- they'd be noise next to a good number.
        if webReadingIsFresh {
            liveClaudeError = nil
            return
        }
        // Still inside a rate-limit wait: skip this round rather than be refused.
        if let liveRetryAfter, liveRetryAfter > Date() { return }
        lastLiveAttempt = Date()
        liveFetchInFlight = true
        Task {
            let failure = await Task.detached(priority: .utility) { ClaudeLiveUsage.refresh() }.value
            self.liveFetchInFlight = false
            self.liveClaudeError = failure?.description
            if case .accessDeclined = failure { self.livePausedByDecline = true }

            if case .rateLimited(let retryAfter) = failure {
                self.consecutiveRateLimits += 1
                let wait = retryAfter ?? ClaudeLiveUsage.backoff(afterFailures: self.consecutiveRateLimits)
                let until = Date().addingTimeInterval(wait)
                self.liveRetryAfter = until
                // Come back exactly when the server said we may, instead of
                // waiting for the next slow tick.
                Timer.scheduledTimer(withTimeInterval: wait + 5, repeats: false) { [weak self] _ in
                    Task { @MainActor in self?.maybeFetchLive(force: true) }
                }
                self.liveClaudeError = "Anthropic is limiting usage checks. Trying again "
                    + "\(Fmt.until(until)). The Claude number below is the last one received."
            } else {
                self.consecutiveRateLimits = 0
                self.liveRetryAfter = nil
            }
            // The new file also triggers FSEvents; the extra call covers failures,
            // which write nothing.
            self.refresh()
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
            codex: report?.codex.map { Self.menuBarText($0, now: now) },
            claude: report?.claude.map { Self.menuBarText($0, now: now) })
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
