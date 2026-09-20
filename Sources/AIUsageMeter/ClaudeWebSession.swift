import AppKit
import WebKit

/// Reads Claude usage the way the claude.ai website itself does.
///
/// Why this exists: `api.anthropic.com/api/oauth/usage` (see `ClaudeLiveUsage`)
/// is rate-limited hard — once tripped it answered `Retry-After: 2493`. The
/// website's own endpoints are a different backend, which is how other menu bar
/// apps refresh every minute.
///
/// How it works, and why it's built this way:
///   - The app owns a `WKWebView`. You sign in on Anthropic's real page inside
///     it, exactly as in a browser. The app never sees your password.
///   - Requests are made **from inside that page** with `fetch()`, so the web
///     view attaches its own cookies. The app never reads, copies or stores the
///     session cookie. Compare that with other apps, which lift the cookie out
///     of Safari's or Chrome's cookie database.
///   - The session lives in the app's own website data store, so signing out
///     inside the window is enough to remove it.
@MainActor
final class ClaudeWebSession: NSObject {
    static let shared = ClaudeWebSession()

    private var webView: WKWebView?
    private var loginWindow: NSWindow?
    private var pendingLoad: [(Bool) -> Void] = []

    /// Notes what happened, so sign-in problems can be diagnosed without a
    /// terminal. Usage numbers and events only -- never cookies or page content.
    static func log(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date()))  \(message)\n"
        let url = ClaudeReadings.directory.appendingPathComponent("debug.log")
        try? FileManager.default.createDirectory(at: ClaudeReadings.directory,
                                                 withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    enum WebFailure: Error, CustomStringConvertible {
        case notSignedIn, http(Int), badResponse(String), pageError(String)
        var description: String {
            switch self {
            case .notSignedIn:
                return "Not signed in to claude.ai. Click \"Sign in to Claude\" in the panel."
            case .http(let code):
                return code == 401 || code == 403
                    ? "claude.ai signed out. Click \"Sign in to Claude\" in the panel."
                    : "claude.ai usage request failed (HTTP \(code))"
            case .badResponse(let what): return "Unexpected reply from claude.ai: \(what)"
            case .pageError(let what): return "claude.ai page problem: \(what)"
            }
        }
    }

    // MARK: - Web view

    private func makeWebView() -> WKWebView {
        if let webView { return webView }
        let config = WKWebViewConfiguration()
        // Persistent store: staying signed in is the point.
        config.websiteDataStore = .default()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 960, height: 720), configuration: config)
        view.navigationDelegate = self
        webView = view
        return view
    }

    /// Loads claude.ai so `fetch()` below runs on that origin (cookies come with it).
    private func loadSiteIfNeeded(_ completion: @escaping (Bool) -> Void) {
        let view = makeWebView()
        if let host = view.url?.host, host.hasSuffix("claude.ai"), !view.isLoading {
            completion(true)
            return
        }
        pendingLoad.append(completion)
        view.load(URLRequest(url: URL(string: "https://claude.ai/")!))
    }

    // MARK: - Reading usage

    /// Runs the website's own usage calls inside the page and returns the raw
    /// JSON, so the response shape can be inspected before it is mapped.
    func fetchRawUsage(completion: @escaping (Result<String, WebFailure>) -> Void) {
        loadSiteIfNeeded { [weak self] ok in
            guard let self, ok else { return completion(.failure(.pageError("could not load claude.ai"))) }

            // `callAsyncJavaScript` runs an async function body and waits for it.
            // `evaluateJavaScript` cannot: handed a promise it fails with
            // "returned a result of an unsupported type".
            let js = """
            const o = await fetch('/api/organizations', { credentials: 'include' });
            if (!o.ok) return JSON.stringify({ __error: 'organizations', status: o.status });
            const orgs = await o.json();
            if (!Array.isArray(orgs) || orgs.length === 0)
              return JSON.stringify({ __error: 'no organizations' });
            // Prefer the org that can chat; otherwise the first one.
            const org = orgs.find(x => (x.capabilities || []).includes('chat')) || orgs[0];
            const u = await fetch('/api/organizations/' + org.uuid + '/usage', { credentials: 'include' });
            if (!u.ok) return JSON.stringify({ __error: 'usage', status: u.status });
            return JSON.stringify({ __orgCount: orgs.length, usage: await u.json() });
            """
            self.webView?.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .failure(let error):
                    Self.log("usage call failed: \(error.localizedDescription)")
                    completion(.failure(.pageError(error.localizedDescription)))
                case .success(let value):
                    guard let text = value as? String else {
                        return completion(.failure(.badResponse("unexpected reply type")))
                    }
                    if let data = text.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        if let status = obj["status"] as? Int {
                            Self.log("usage call returned HTTP \(status)")
                            return completion(status == 401 || status == 403
                                              ? .failure(.notSignedIn) : .failure(.http(status)))
                        }
                        if let err = obj["__error"] as? String {
                            return completion(.failure(.badResponse(err)))
                        }
                    }
                    Self.log("usage call ok (\(text.count) bytes)")
                    completion(.success(text))
                }
            }
        }
    }

    // MARK: - Sign-in window

    /// Opens Anthropic's real sign-in page in a window this app owns.
    ///
    /// Order matters. A menu bar app runs as an "accessory", which has no
    /// windows and cannot take keyboard focus, so its windows swallow clicks.
    /// It must become a regular foreground app *before* the window is shown and
    /// activated.
    func showLoginWindow() {
        let view = makeWebView()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()

        if loginWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 760),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Sign in to Claude"
            window.contentView = view
            window.isReleasedWhenClosed = false     // reused for the next sign-in
            window.delegate = self
            window.center()
            loginWindow = window
        }

        view.load(URLRequest(url: URL(string: "https://claude.ai/login")!))
        loginWindow?.makeKeyAndOrderFront(nil)
        loginWindow?.orderFrontRegardless()
        loginWindow?.makeFirstResponder(view)
        Self.log("sign-in window opened")
    }

    func closeLoginWindow() {
        guard let loginWindow, loginWindow.isVisible else { return }
        loginWindow.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)       // back to menu bar only
        Self.log("sign-in window closed")
    }
}

extension ClaudeWebSession: NSWindowDelegate {
    /// Closing the sign-in window must not quit a menu bar app.
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            NSApp.setActivationPolicy(.accessory)
            Self.log("sign-in window dismissed by user")
        }
    }
}

extension ClaudeWebSession: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            let waiting = self.pendingLoad
            self.pendingLoad = []
            waiting.forEach { $0(true) }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            let waiting = self.pendingLoad
            self.pendingLoad = []
            waiting.forEach { $0(false) }
        }
    }
}
