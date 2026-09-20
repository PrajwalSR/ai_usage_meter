import AppKit
import SwiftUI

// MARK: - `--scan`: check the numbers without the UI

// `AIUsageMeter --scan` runs one index pass and prints the result.
// `--rebuild` deletes the cache first. Neither makes network requests: live
// Claude readings already saved to disk are shown, but no new check is made.
if CommandLine.arguments.contains("--scan") {
    // Deleting the cache under a running app would break it, so `--rebuild`
    // needs the same lock the app holds. Kept alive until the process exits.
    var rebuildLock: InstanceLock?
    if CommandLine.arguments.contains("--rebuild") {
        rebuildLock = InstanceLock()
        guard rebuildLock != nil else {
            print("AI Usage Meter is running. Quit it first, then run --rebuild again.")
            exit(1)
        }
        let base = Database.defaultURL
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(
                at: base.deletingLastPathComponent().appendingPathComponent(base.lastPathComponent + suffix))
        }
    }
    defer { _ = rebuildLock }
    do {
        let now = Date()
        let report = try UsageIndex().refresh(now: now)
        print(String(format: "pass took %.2fs\n", report.scanDuration))
        for r in [report.codex, report.claude].compactMap({ $0 }) {
            print("== \(r.providerName) ==")
            switch r.display(now: now) {
            case .available(let head, let others, let source):
                for w in [head] + others {
                    let resets = w.resetsAt.map { "resets \(Fmt.clock($0)) (\(Fmt.until($0, now: now)))" } ?? ""
                    print("  \(w.usedPercent)% of \(w.windowLabel) window"
                          + (w.limitId.map { " [\($0)]" } ?? "") + "  \(resets)")
                }
                print("  source:  \(Fmt.sourceLine(source, now: now))"
                      + (source.planType.map { "  plan: \($0)" } ?? ""))
            case .expired(let source):
                print("  usage unknown: every window has reset since the reading")
                print("  source:  \(Fmt.sourceLine(source, now: now))")
            case .unavailable:
                print("  usage unavailable: \(r.unavailableNote)")
            }
            print("  tokens:  5h \(Fmt.tokens(r.last5Hours.total)) / \(r.last5Hours.messages) msg, "
                  + "7d \(Fmt.tokens(r.last7Days.total)) / \(r.last7Days.messages) msg")
            print("  files:   \(r.filesSeen) seen, \(r.filesReadThisPass) read this pass\n")
        }
        for e in report.errors { print("! \(e)") }
    } catch {
        print("failed: \(error)")
        exit(1)
    }
    exit(0)
}

// MARK: - `--check-claude`: one live check, with the server's reply spelled out

// Prints the HTTP status, any rate-limit headers and the server's error text, so
// a failing live check can be diagnosed. It never prints the login.
if CommandLine.arguments.contains("--check-claude") {
    let failure = ClaudeLiveUsage.refresh()
    if let r = ClaudeLiveUsage.lastResponse {
        print("HTTP \(r.status)")
        if let ra = r.retryAfter { print("Retry-After: \(ra)") }
        for (k, v) in r.rateLimitHeaders.sorted(by: { $0.key < $1.key }) { print("\(k): \(v)") }
        if let body = r.bodyPreview { print("body: \(body)") }
    }
    print(failure.map { "result: \($0.description)" } ?? "result: success, reading saved")
    exit(failure == nil ? 0 : 1)
}

// MARK: - `--check-claude-web`: try the claude.ai website route

// Signs in through a window this app owns (if needed) and prints the raw usage
// JSON, so the response shape can be checked. Prints no cookie: the request is
// made inside the page, which attaches its own.
if CommandLine.arguments.contains("--check-claude-web") {
    let app = NSApplication.shared
    MainActor.assumeIsolated {
        app.setActivationPolicy(.accessory)
        var attempts = 0
        @MainActor func attempt() {
            attempts += 1
            ClaudeWebSession.shared.fetchRawUsage { result in
                switch result {
                case .success(let json):
                    print(json)
                    exit(0)
                case .failure(let failure):
                    if case .notSignedIn = failure, attempts == 1 {
                        print("Not signed in — opening the Claude sign-in window.")
                        print("Sign in there; this keeps checking every 5 s.")
                        ClaudeWebSession.shared.showLoginWindow()
                    } else {
                        print("attempt \(attempts): \(failure.description)")
                    }
                    if attempts > 60 { print("giving up"); exit(1) }
                    Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { _ in
                        MainActor.assumeIsolated { attempt() }
                    }
                }
            }
        }
        attempt()
    }
    app.run()
}

// MARK: - Menu bar app

@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private let store = UsageStore()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()

    /// A menu bar app must survive its windows: the sign-in window closing must
    /// not quit it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only: no Dock icon, no window (also set via LSUIElement).
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)

        popover.behavior = .transient
        store.onChange = { [weak self] in self?.render() }
        store.refresh()
        render()
    }

    private func render() {
        statusItem.button?.image = store.menuBarImage
        statusItem.button?.title = ""
        // Rebuild the panel only while it's visible.
        guard popover.isShown || popover.contentViewController == nil else { return }
        updateContent()
    }

    private func updateContent() {
        let view = UsagePanel(
            report: store.report,
            isScanning: store.isScanning,
            isWatching: store.isWatching,
            liveClaudeEnabled: store.liveClaudeEnabled,
            webSignedIn: store.webSignedIn,
            onSignInToClaudeWeb: { [weak self] in self?.store.signInToClaudeWeb() },
            launchAtLoginAvailable: store.launchAtLoginAvailable,
            launchesAtLogin: store.launchesAtLogin,
            errorText: [store.indexError, store.webError, store.liveClaudeError].compactMap { $0 }.first,
            now: Date(),
            onRefresh: { [weak self] in self?.store.refreshAll() },
            onToggleLiveClaude: { [weak self] on in self?.store.setLiveClaudeEnabled(on) },
            onToggleLaunchAtLogin: { [weak self] on in self?.store.setLaunchAtLogin(on) },
            onQuit: { NSApp.terminate(nil) })
        if let hosting = popover.contentViewController as? NSHostingController<UsagePanel> {
            hosting.rootView = view
        } else {
            popover.contentViewController = NSHostingController(rootView: view)
        }
        if let vc = popover.contentViewController {
            popover.contentSize = vc.view.fittingSize
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // A good moment for a fresh Claude number: the user is looking, and
            // it keeps background checks rare.
            store.panelOpened()
            updateContent()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

// One copy of the app at a time: two would index the same logs at once, and
// `--rebuild` must not delete the cache under a running app. The lock is held
// for the life of the process.
guard let appLock = InstanceLock() else {
    let alert = NSAlert()
    alert.messageText = "AI Usage Meter is already running"
    alert.informativeText = "Look for it in the menu bar. Only one copy can run at a time."
    alert.runModal()
    exit(0)
}

// Top-level code runs on the main thread but isn't main-actor isolated, so the
// controller is created under an explicit assumption.
let app = NSApplication.shared
MainActor.assumeIsolated {
    let controller = AppController()
    app.delegate = controller
    // NSApplication holds its delegate weakly; keep a strong reference.
    objc_setAssociatedObject(app, "AIUsageMeterController", controller, .OBJC_ASSOCIATION_RETAIN)
}
withExtendedLifetime(appLock) { app.run() }
