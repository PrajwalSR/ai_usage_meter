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

    /// Sites whose data belongs to each provider, for clearing one provider's
    /// sign-in out of the default store the original two accounts share.
    private static func siteDomains(_ provider: Provider) -> [String] {
        provider == .claude ? ["claude.ai", "claude.com", "anthropic.com"] : ["chatgpt.com", "openai.com"]
    }

    /// Sites the providers send you to for "Continue with Google / Apple /
    /// Microsoft". Their pages may open in the sign-in window, and their
    /// cookies are removed on sign-out.
    nonisolated static let identityDomains = ["accounts.google.com", "accounts.youtube.com", "google.com",
                                  "appleid.apple.com", "login.live.com", "login.microsoftonline.com"]

    /// `host` is `domain` or one of its subdomains ("notopenai.com" is not).
    nonisolated static func isHost(_ host: String, within domain: String) -> Bool {
        let h = host.lowercased()
        return h == domain || h.hasSuffix("." + domain)
    }

    /// Whether a page may open in this session's windows without leaving the
    /// provider's own sign-in.
    func isTrusted(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", let host = url.host else { return false }
        let own = Self.siteDomains(home.host == "claude.ai" ? .claude : .codex)
        return (own + Self.identityDomains).contains { Self.isHost(host, within: $0) }
    }

    /// Signs the account out: erases its cookies and site data, and drops the
    /// page so the next sign-in starts clean. The account itself stays.
    static func signOut(_ account: Account, completion: @escaping @Sendable () -> Void) {
        if let session = sessions.removeValue(forKey: account.id) { session.discardPage() }
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        guard account.isLegacy else {
            WKWebsiteDataStore(forIdentifier: account.id)
                .removeData(ofTypes: types, modifiedSince: .distantPast, completionHandler: completion)
            return
        }
        // The default store also holds the other provider's sign-in: only
        // this provider's sites are removed.
        let store = WKWebsiteDataStore.default()
        store.fetchDataRecords(ofTypes: types) { records in
            let domains = siteDomains(account.provider) + identityDomains
            let mine = records.filter { r in domains.contains { isHost(r.displayName, within: $0) } }
            store.removeData(ofTypes: types, for: mine, completionHandler: completion)
        }
    }

    /// Deletes a removed account's sign-in. WebKit refuses while a page still
    /// uses the store ("Data store is in use"), so it is tried again a little
    /// later; anything still left is deleted at the next launch by
    /// `removeOrphanedStores`.
    static func removeAccountData(_ account: Account) {
        signOut(account) {}
        guard !account.isLegacy else { return }
        func attempt(_ delays: [TimeInterval]) {
            WKWebsiteDataStore.remove(forIdentifier: account.id) { error in
                guard error != nil, let next = delays.first else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + next) { attempt(Array(delays.dropFirst())) }
            }
        }
        attempt([5, 60])
    }

    /// At launch, before any page exists: deletes stores whose account is gone.
    /// Done on the folders directly: WebKit's own store listing crashes when
    /// asked before WebKit has started, and nothing uses these folders yet.
    static func removeOrphanedStores(keeping accounts: [Account]) {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let keep = Set(accounts.map(\.id))
        let fm = FileManager.default
        let stores = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/WebKit/\(bundleID)/WebsiteDataStore", isDirectory: true)
        for name in (try? fm.contentsOfDirectory(atPath: stores.path)) ?? [] {
            guard let id = UUID(uuidString: name), !keep.contains(id) else { continue }
            do {
                try fm.removeItem(at: stores.appendingPathComponent(name))
            } catch {
                log("could not delete a removed account's sign-in: \(error.localizedDescription)")
            }
        }
    }

    private func discardPage() {
        closeLoginWindow()
        pendingLoad = []
        webView?.stopLoading()
        loginWindow?.contentView = nil
        loginWindow = nil
        webView = nil
    }

    /// The scripts run inside the signed-in pages. They only read: every
    /// request is a plain GET (`fetch` with no `method`), so the app can never
    /// change anything on an account, such as using a limit reset. A test
    /// checks this.
    nonisolated static let claudeScript = """
        const o = await fetch('/api/organizations', { credentials: 'include' });
        if (!o.ok) return JSON.stringify({ __error: 'organizations', status: o.status });
        const orgs = await o.json();
        if (!Array.isArray(orgs) || orgs.length === 0)
          return JSON.stringify({ __error: 'no organizations' });
        const org = orgs.find(x => (x.capabilities || []).includes('chat')) || orgs[0];
        const u = await fetch('/api/organizations/' + org.uuid + '/usage', { credentials: 'include' });
        if (!u.ok) return JSON.stringify({ __error: 'usage', status: u.status });
        // The plan is named on the organization, not in the usage reply. Only
        // the plan fields are passed on: no ids, names or billing details.
        const plan = { tier: org.rate_limit_tier || null, capabilities: org.capabilities || [] };
        return JSON.stringify({ __orgCount: orgs.length, plan: plan, usage: await u.json() });
        """

    nonisolated static let chatGPTScript = """
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
        const usage = await u.json();
        // When each limit reset expires (the usage reply only has a count).
        // Optional: if this request fails, usage still comes back. Only the
        // status and expiry of each reset are passed on.
        let resets = null;
        try {
          const r = await fetch('/backend-api/wham/rate-limit-reset-credits', {
            credentials: 'include',
            headers: { 'Authorization': 'Bearer ' + token }
          });
          if (r.ok) {
            const body = await r.json();
            resets = (body.credits || []).map(c => ({ status: c.status, expires_at: c.expires_at }));
          }
        } catch (_) {}
        return JSON.stringify({ usage: usage, resets: resets });
        """

    /// claude.ai: usage for the Claude account.
    private static func makeClaude(dataStoreID: UUID?) -> WebSession { WebSession(
        siteName: "Claude",
        home: URL(string: "https://claude.ai/")!,
        login: URL(string: "https://claude.ai/login")!,
        dataStoreID: dataStoreID,
        script: claudeScript) }

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
        script: chatGPTScript) }

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

    /// Called when the sign-in window lands on a page of the site that isn't
    /// part of signing in (after sign-in the site opens its chat), so the
    /// owner can check usage right away and close the window.
    var onLeftSignInPages: (() -> Void)?

    /// Whether the sign-in window is open, so a failed check during sign-in
    /// isn't reported as a problem.
    var isSigningIn: Bool { loginWindow?.isVisible == true }

    /// Login, sign-up and verification pages on either site.
    private static func isSignInPage(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        return ["login", "log-in", "signin", "sign-in", "signup", "auth", "verify", "magic-link", "oauth"]
            .contains { path.contains($0) }
    }

    /// How long one usage check may take. A page that never finishes loading,
    /// or a request that never answers, would otherwise leave the check
    /// pending forever: no error, and no further checks for this account.
    static let fetchTimeout: TimeInterval = 45

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
        // Kept small: about two lines a minute would otherwise grow forever.
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
           size > 1_000_000 {
            let old = url.appendingPathExtension("1")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
        }
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
        // Google refuses to sign in a page whose user agent says "embedded web
        // view" (WebKit's default ends without Safari's "Version/… Safari/…").
        // This is a real WebKit page, so it says what Safari says.
        config.applicationNameForUserAgent = Self.safariUserAgentSuffix
        // Popups only from a click, never from a script on its own.
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 960, height: 720), configuration: config)
        view.navigationDelegate = self
        view.uiDelegate = self
        webView = view
        return view
    }

    /// The end of Safari's user agent, using the installed Safari's version.
    static var safariUserAgentSuffix: String {
        let plist = URL(fileURLWithPath: "/Applications/Safari.app/Contents/Info.plist")
        let version = (NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? "18.0"
        return "Version/\(version) Safari/605.1.15"
    }

    /// Windows the page opened itself ("Continue with Google" opens one).
    private var popups: [NSWindow] = []

    fileprivate func openPopup(_ configuration: WKWebViewConfiguration,
                               features: WKWindowFeatures) -> WKWebView {
        let width = features.width.map { CGFloat($0.doubleValue) } ?? 520
        let height = features.height.map { CGFloat($0.doubleValue) } ?? 680
        // The configuration WebKit hands over must be used as is: it ties the
        // popup to its opener, which is how the result gets back to the page.
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height),
                             configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        let window = NSWindow(contentRect: view.frame,
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Sign in to \(siteName)"
        window.contentView = view
        window.isReleasedWhenClosed = false
        window.delegate = self
        if let parent = loginWindow { parent.addChildWindow(window, ordered: .above) }
        window.center()
        window.makeKeyAndOrderFront(nil)
        popups.append(window)
        Self.log("\(siteName): sign-in popup opened")
        return view
    }

    fileprivate func closePopup(_ view: WKWebView) {
        guard let index = popups.firstIndex(where: { $0.contentView === view }) else { return }
        let window = popups.remove(at: index)
        window.parent?.removeChildWindow(window)
        window.orderOut(nil)
        window.contentView = nil
        loginWindow?.makeKeyAndOrderFront(nil)
    }

    /// Loads claude.ai so `fetch()` below runs on that origin (cookies come with it).
    private func loadSiteIfNeeded(_ completion: @escaping (Bool) -> Void) {
        let view = makeWebView()
        if let host = view.url?.host, host == home.host, !view.isLoading {
            completion(true)
            return
        }
        // The sign-in window shows this same page. Loading the site now would
        // pull the user off the sign-in page they are typing in, so wait.
        guard !isSigningIn else { return completion(false) }
        pendingLoad.append(completion)
        view.load(URLRequest(url: home))
    }

    /// Drops a page that stopped responding, so the next check starts fresh.
    /// Left alone while the user is signing in, so the window isn't emptied
    /// under them.
    private func resetPage() {
        pendingLoad = []
        guard loginWindow?.isVisible != true else { return }
        webView?.stopLoading()
        loginWindow?.contentView = nil
        loginWindow = nil
        webView = nil
    }

    // MARK: - Reading usage

    /// Runs the website's own usage calls inside the page and returns the raw
    /// JSON, so the response shape can be inspected before it is mapped.
    func fetchRawUsage(completion: @escaping (Result<String, WebFailure>) -> Void) {
        // Whichever comes first, the answer or the time limit, wins; the other
        // is ignored.
        var finished = false
        let completion: (Result<String, WebFailure>) -> Void = { result in
            guard !finished else { return }
            finished = true
            completion(result)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fetchTimeout) { [weak self] in
            guard let self, !finished else { return }
            Self.log("\(self.siteName): no answer after \(Int(Self.fetchTimeout))s, reloading the page")
            self.resetPage()
            completion(.failure(.pageError("\(self.siteName) didn't respond. Trying again shortly.")))
        }

        loadSiteIfNeeded { [weak self] ok in
            guard let self, ok else {
                return completion(.failure(.pageError("could not load \(self?.siteName ?? "the site")")))
            }

            // `callAsyncJavaScript` runs an async function body and waits for it.
            // `evaluateJavaScript` cannot: handed a promise it fails with
            // "returned a result of an unsupported type".
            // Only on the site itself: `fetch('/api/…')` is relative to whatever
            // page is showing.
            guard let view = self.webView, view.url?.host == self.home.host else {
                return completion(.failure(.pageError("\(self.siteName) isn't loaded")))
            }
            // The app's own script world: the page's scripts can't replace
            // `fetch` or `JSON` there to change what the app reads.
            let js = self.script
            view.callAsyncJavaScript(js, arguments: [:], in: nil, in: .defaultClient) { result in
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
                                  styleMask: [.titled, .closable, .resizable],
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
        popups.compactMap { $0.contentView as? WKWebView }.forEach(closePopup)
        guard let loginWindow, loginWindow.isVisible else { return }
        loginWindow.orderOut(nil)
        Self.settleActivationPolicy()
        Self.log("\(siteName): sign-in window closed")
    }

    /// Back to menu bar only, unless another account's sign-in window is
    /// still open: that one would stop taking clicks and typing.
    static func settleActivationPolicy(closing: NSWindow? = nil) {
        let anyOpen = sessions.values.contains { session in
            guard let window = session.loginWindow, window !== closing else { return false }
            return window.isVisible
        }
        if !anyOpen { NSApp.setActivationPolicy(.accessory) }
    }
}

extension WebSession: NSWindowDelegate {
    /// Closing the sign-in window must not quit a menu bar app.
    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard let window = notification.object as? NSWindow else { return }
            // A popup closed with its own close button.
            if let view = window.contentView as? WKWebView, popups.contains(window) {
                return closePopup(view)
            }
            popups.compactMap { $0.contentView as? WKWebView }.forEach(closePopup)
            Self.settleActivationPolicy(closing: window)
            Self.log("\(self.siteName): sign-in window dismissed by user")
        }
    }
}

extension WebSession: WKUIDelegate {
    /// Without this, a page's `window.open` does nothing at all, so a sign-in
    /// button that opens a popup (Google's does) seems dead.
    nonisolated func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                             for navigationAction: WKNavigationAction,
                             windowFeatures: WKWindowFeatures) -> WKWebView? {
        MainActor.assumeIsolated {
            let url = navigationAction.request.url
            guard isSigningIn, webView === self.webView, isTrusted(url) else {
                // Anything else (a link in a chat, say) belongs in the browser,
                // not in a window titled "Sign in".
                if let url, url.scheme == "https", navigationAction.navigationType == .linkActivated {
                    NSWorkspace.shared.open(url)
                }
                Self.log("\(siteName): popup to \(url?.host ?? "a blank page") refused")
                return nil
            }
            return openPopup(configuration, features: windowFeatures)
        }
    }

    /// The popup calls `window.close()` once sign-in is done.
    nonisolated func webViewDidClose(_ webView: WKWebView) {
        MainActor.assumeIsolated { closePopup(webView) }
    }
}

extension WebSession: WKNavigationDelegate {
    /// The provider's sites and the sign-in providers load as usual. A link to
    /// anywhere else opens in the user's browser. Other redirects are allowed
    /// only while signing in (a company sign-in can live anywhere), and the
    /// window title then names the site, since there is no address bar.
    nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                             decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        MainActor.assumeIsolated {
            let url = navigationAction.request.url
            guard navigationAction.targetFrame?.isMainFrame == true,
                  let scheme = url?.scheme, scheme == "https" || scheme == "http"
            else { return decisionHandler(.allow) }       // frames, about:blank
            if isTrusted(url) { return decisionHandler(.allow) }
            if navigationAction.navigationType == .linkActivated, let url {
                NSWorkspace.shared.open(url)
                return decisionHandler(.cancel)
            }
            decisionHandler(isSigningIn ? .allow : .cancel)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            guard let window = webView.window, let host = webView.url?.host else { return }
            window.title = "Sign in to \(siteName) — \(host)"
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            // A popup's pages are not the session's own page.
            guard webView === self.webView else { return }
            let waiting = self.pendingLoad
            self.pendingLoad = []
            waiting.forEach { $0(true) }
            if self.isSigningIn, let url = webView.url, url.host == self.home.host,
               !Self.isSignInPage(url) {
                self.onLeftSignInPages?()
            }
        }
    }

    /// The page couldn't even start loading: offline, or just woken from sleep.
    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                             withError error: Error) {
        Task { @MainActor in
            guard webView === self.webView else { return }
            let waiting = self.pendingLoad
            self.pendingLoad = []
            waiting.forEach { $0(false) }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            guard webView === self.webView else { return }
            let waiting = self.pendingLoad
            self.pendingLoad = []
            waiting.forEach { $0(false) }
        }
    }
}
