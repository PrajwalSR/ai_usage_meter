import AppKit
import WebKit

/// Reads usage the way a provider's own website does.
///
/// Why this exists: `api.anthropic.com/api/oauth/usage` (which earlier builds
/// read with the Claude Code login from the Keychain) is rate-limited hard —
/// once tripped it answered `Retry-After: 2493`. The website's own endpoints are a different backend, which is how other menu bar
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
final class WebSession: NSObject {
    private static var sessions: [UUID: WebSession] = [:]

    /// The original two sign-ins keep WebKit's default store. New accounts get
    /// a persistent store identified by their own UUID, so signing in to one
    /// cannot replace another account's cookies.
    static func forAccount(_ account: Account) -> WebSession {
        if let session = sessions[account.id] { return session }
        let session: WebSession
        switch account.provider {
        case .claude: session = makeClaude(dataStoreID: account.isLegacy ? nil : account.id)
        case .codex: session = makeChatGPT(dataStoreID: account.isLegacy ? nil : account.id)
        }
        sessions[account.id] = session
        return session
    }

    static var claude: WebSession {
        forAccount(Account(id: AccountRegistry.legacyClaudeID, provider: .claude,
                           label: "Claude", pinned: true))
    }

    static var chatGPT: WebSession {
        forAccount(Account(id: AccountRegistry.legacyCodexID, provider: .codex,
                           label: "Codex", pinned: true))
    }

    /// Delete a removed account's persistent sign-in. The original default
    /// store is shared by both providers, so it is left alone for legacy IDs.
    static func removeAccountData(_ account: Account, completion: @escaping (Error?) -> Void) {
        if let session = sessions.removeValue(forKey: account.id) {
            session.closeLoginWindow()
            session.loginWindow?.contentView = nil
            session.loginWindow = nil
            session.webView = nil
        }
        guard !account.isLegacy else { completion(nil); return }
        WKWebsiteDataStore.remove(forIdentifier: account.id) { error in
            completion(error)
        }
    }

    /// claude.ai: usage for the Claude account.
    private static func makeClaude(dataStoreID: UUID?) -> WebSession { WebSession(
        siteName: "Claude",
        home: URL(string: "https://claude.ai/")!,
        login: URL(string: "https://claude.ai/login")!,
        dataStoreID: dataStoreID,
        script: """
        const o = await fetch('/api/organizations', { credentials: 'include' });
        if (!o.ok) return JSON.stringify({ __error: 'organizations', status: o.status });
        const orgs = await o.json();
        if (!Array.isArray(orgs) || orgs.length === 0)
          return JSON.stringify({ __error: 'no organizations' });
        const org = orgs.find(x => (x.capabilities || []).includes('chat')) || orgs[0];
        const u = await fetch('/api/organizations/' + org.uuid + '/usage', { credentials: 'include' });
        if (!u.ok) return JSON.stringify({ __error: 'usage', status: u.status });
        return JSON.stringify({ __orgCount: orgs.length, usage: await u.json() });
        """) }

    /// chatgpt.com: usage for the Codex limit on the ChatGPT plan.
    ///
    /// The website's own pages call `/backend-api/...` with a bearer token that
    /// `/api/auth/session` hands to the page. Both calls run inside the page, so
    /// the token never leaves it and the app never stores anything.
    private static func makeChatGPT(dataStoreID: UUID?) -> WebSession { WebSession(
        siteName: "ChatGPT",
        home: URL(string: "https://chatgpt.com/codex/settings/usage")!,
        login: URL(string: "https://chatgpt.com/auth/login")!,
        dataStoreID: dataStoreID,
        script: """
        const s = await fetch('/api/auth/session', { credentials: 'include' });
        if (!s.ok) return JSON.stringify({ __error: 'session', status: s.status });
        const session = await s.json();
        const token = session && session.accessToken;
        if (!token) return JSON.stringify({ __error: 'session', status: 401 });
        const u = await fetch('/backend-api/wham/usage', {
          credentials: 'include',
          headers: { 'Authorization': 'Bearer ' + token }
        });
        if (!u.ok) return JSON.stringify({ __error: 'usage', status: u.status });
        return JSON.stringify({ usage: await u.json() });
        """) }

    let siteName: String
    private let home: URL
    private let login: URL
    private let dataStoreID: UUID?
    private let script: String

    init(siteName: String, home: URL, login: URL, dataStoreID: UUID? = nil, script: String) {
        self.siteName = siteName
        self.home = home
        self.login = login
        self.dataStoreID = dataStoreID
        self.script = script
        super.init()
    }

    private var webView: WKWebView?
    private var loginWindow: NSWindow?
    private var pendingLoad: [(Bool) -> Void] = []

    /// Exposes the actual WebKit store identifier for isolation checks.
    var websiteDataStoreIdentifier: UUID? {
        makeWebView().configuration.websiteDataStore.identifier
    }

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
                return "Not signed in. Use the sign-in link in the panel."
            case .http(let code):
                return code == 401 || code == 403
                    ? "Signed out. Use the sign-in link in the panel."
                    : "Usage request failed (HTTP \(code))"
            case .badResponse(let what): return "Unexpected reply from the website: \(what)"
            case .pageError(let what): return "Website problem: \(what)"
            }
        }
    }

    // MARK: - Web view

    private func makeWebView() -> WKWebView {
        if let webView { return webView }
        let config = WKWebViewConfiguration()
        // Persistent store: staying signed in is the point.
        config.websiteDataStore = dataStoreID.map(WKWebsiteDataStore.init(forIdentifier:)) ?? .default()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 960, height: 720), configuration: config)
        view.navigationDelegate = self
        webView = view
        return view
    }

    /// Loads claude.ai so `fetch()` below runs on that origin (cookies come with it).
    private func loadSiteIfNeeded(_ completion: @escaping (Bool) -> Void) {
        let view = makeWebView()
        if let host = view.url?.host, host == home.host, !view.isLoading {
            completion(true)
            return
        }
        pendingLoad.append(completion)
        view.load(URLRequest(url: home))
    }

    // MARK: - Reading usage

    /// Runs the website's own usage calls inside the page and returns the raw
    /// JSON, so the response shape can be inspected before it is mapped.
    func fetchRawUsage(completion: @escaping (Result<String, WebFailure>) -> Void) {
        loadSiteIfNeeded { [weak self] ok in
            guard let self, ok else {
                return completion(.failure(.pageError("could not load \(self?.siteName ?? "the site")")))
            }

            // `callAsyncJavaScript` runs an async function body and waits for it.
            // `evaluateJavaScript` cannot: handed a promise it fails with
            // "returned a result of an unsupported type".
            let js = self.script
            self.webView?.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .failure(let error):
                    Self.log("\(self.siteName): usage call failed: \(error.localizedDescription)")
                    completion(.failure(.pageError(error.localizedDescription)))
                case .success(let value):
                    guard let text = value as? String else {
                        return completion(.failure(.badResponse("unexpected reply type")))
                    }
                    if let data = text.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        if let status = obj["status"] as? Int {
                            Self.log("\(self.siteName): usage call returned HTTP \(status)")
                            return completion(status == 401 || status == 403
                                              ? .failure(.notSignedIn) : .failure(.http(status)))
                        }
                        if let err = obj["__error"] as? String {
                            return completion(.failure(.badResponse(err)))
                        }
                    }
                    Self.log("\(self.siteName): usage call ok (\(text.count) bytes)")
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
            window.title = "Sign in to \(siteName)"
            window.contentView = view
            window.isReleasedWhenClosed = false     // reused for the next sign-in
            window.delegate = self
            window.center()
            loginWindow = window
        }

        view.load(URLRequest(url: login))
        loginWindow?.makeKeyAndOrderFront(nil)
        loginWindow?.orderFrontRegardless()
        loginWindow?.makeFirstResponder(view)
        Self.log("\(siteName): sign-in window opened")
    }

    func closeLoginWindow() {
        guard let loginWindow, loginWindow.isVisible else { return }
        loginWindow.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)       // back to menu bar only
        Self.log("\(siteName): sign-in window closed")
    }
}

extension WebSession: NSWindowDelegate {
    /// Closing the sign-in window must not quit a menu bar app.
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            NSApp.setActivationPolicy(.accessory)
            Self.log("\(self.siteName): sign-in window dismissed by user")
        }
    }
}

extension WebSession: WKNavigationDelegate {
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
