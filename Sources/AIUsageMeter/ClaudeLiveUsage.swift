import Foundation
import Security

/// Optional live check of Claude's allowance, using the login Claude Code saved.
///
/// Off by default: it reads a credential and makes network requests, so the user
/// turns it on in the panel ("Check Claude usage live"). When on, it runs at
/// launch, every `pollInterval`, and on manual refresh.
///
/// It asks Anthropic for the same data Claude Code's `/usage` screen shows. The
/// endpoint is undocumented and may change; on failure the panel shows why and
/// the app falls back to the status-line reading, if there is one.
///
/// Credential handling (see SECURITY.md):
///   - The token is read from the Keychain item Claude Code created,
///     "Claude Code-credentials". macOS asks the user first.
///   - It is used for one request, sent only to api.anthropic.com over an
///     ephemeral session (no disk cache, cookies or redirects), and never
///     intentionally logged or written to disk. Swift gives no guarantee about
///     when the string's memory is cleared.
///   - If the user declines Keychain access, `Failure.accessDeclined` is returned
///     and `UsageStore` stops asking until the user tries again.
///
/// The result goes to `ClaudeReadings.liveFileURL`, separate from the status
/// line's file.
enum ClaudeLiveUsage {
    /// Background check interval. Deliberately slow: Anthropic rate-limits this
    /// endpoint (HTTP 429), and a check every 5 minutes, all day, was enough to
    /// be refused for hours. Most updates come from the cheaper triggers instead
    /// (opening the panel, pressing refresh), see `UsageStore.maybeFetchLive`.
    static let pollInterval: TimeInterval = 30 * 60
    /// Never ask more often than this, whatever asks for a check -- except the
    /// refresh button, which the user pressed on purpose. Anthropic's limit on
    /// this endpoint is strict: once tripped it answered `rate_limit_error` with
    /// `Retry-After: 2493` (41 minutes).
    static let minimumInterval: TimeInterval = 10 * 60

    enum Failure: Error, CustomStringConvertible {
        case noCredential, accessDeclined, badCredential, http(Int), network(String), badResponse
        /// Anthropic refused because we asked too often. `retryAfter` is the
        /// server's own wait time when it sends one.
        case rateLimited(retryAfter: TimeInterval?)
        var description: String {
            switch self {
            case .noCredential: return "Claude Code login not found in Keychain. Log in to Claude Code first."
            case .accessDeclined: return "Keychain access was declined, so live checks are paused. Press ⟳ to try again."
            case .badCredential: return "Claude login in Keychain has an unexpected format"
            case .http(let code): return code == 401
                ? "Claude login expired — open Claude Code once to refresh it"
                : "Anthropic usage request failed (HTTP \(code))"
            case .rateLimited(let retryAfter):
                let wait = retryAfter.map { " Waiting \(Fmt.countdown(to: Date().addingTimeInterval($0)))." } ?? ""
                return "Anthropic is limiting usage checks right now.\(wait) The number below is the last one received."
            case .network(let m): return "Could not reach Anthropic: \(m)"
            case .badResponse: return "Unexpected usage response from Anthropic"
            }
        }
    }

    /// What the last request got back, for the `--check-claude` diagnostic.
    /// Never holds credentials: status, headers of interest, and the server's own
    /// error text only.
    struct LastResponse: Sendable {
        var status: Int
        var retryAfter: String?
        var rateLimitHeaders: [String: String]
        var bodyPreview: String?
    }
    nonisolated(unsafe) private(set) static var lastResponse: LastResponse?

    /// Fetches and writes a fresh reading. Call off the main thread.
    static func refresh() -> Failure? {
        let token: String
        switch accessToken() {
        case .success(let t): token = t
        case .failure(let f): return f
        }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.timeoutInterval = 15
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        // Identify this app honestly. Requests with no name are easier for a
        // server to treat as suspicious traffic.
        req.setValue("AIUsageMeter/0.1 (macOS; personal usage meter)",
                     forHTTPHeaderField: "User-Agent")

        let sem = DispatchSemaphore(value: 0)
        var body: Data?
        var status = 0
        var retryAfter: TimeInterval?
        var netError: String?
        session.dataTask(with: req) { data, resp, err in
            body = data
            let http = resp as? HTTPURLResponse
            status = http?.statusCode ?? 0
            // Retry-After is seconds, or an HTTP date.
            if let raw = http?.value(forHTTPHeaderField: "Retry-After") {
                if let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespaces)) {
                    retryAfter = seconds
                } else if let date = httpDateFormatter.date(from: raw) {
                    retryAfter = max(0, date.timeIntervalSinceNow)
                }
            }
            netError = err?.localizedDescription

            // Diagnostic snapshot: no credential is part of a response.
            var limitHeaders: [String: String] = [:]
            for (k, v) in (http?.allHeaderFields ?? [:]) {
                let key = "\(k)".lowercased()
                if key.contains("ratelimit") || key.contains("retry") {
                    limitHeaders[key] = "\(v)"
                }
            }
            lastResponse = LastResponse(
                status: status,
                retryAfter: http?.value(forHTTPHeaderField: "Retry-After"),
                rateLimitHeaders: limitHeaders,
                bodyPreview: status == 200 ? nil : data.map {
                    String(decoding: $0.prefix(400), as: UTF8.self)
                })
            sem.signal()
        }.resume()
        sem.wait()

        if let netError { return .network(netError) }
        if status == 429 { return .rateLimited(retryAfter: retryAfter) }
        guard status == 200 else { return .http(status) }
        guard let body,
              let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return .badResponse }

        var windows: [String: Any] = [:]
        for key in ["five_hour", "seven_day"] {
            guard let w = obj[key] as? [String: Any],
                  let used = JSONPath.double(w, "utilization") else { continue }
            var entry: [String: Any] = ["used_percentage": used]
            if let epoch = resetEpoch(w["resets_at"]) { entry["resets_at"] = epoch }
            windows[key] = entry
        }
        guard !windows.isEmpty else { return .badResponse }

        let payload: [String: Any] = [
            "received_at": Date().timeIntervalSince1970,
            "rate_limits": windows,
        ]
        let url = ClaudeReadings.liveFileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              (try? data.write(to: url, options: [.atomic, .noFileProtection])) != nil
        else { return .badResponse }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return nil
    }

    private static let httpDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    /// How long to wait after being refused, when the server doesn't say.
    /// Doubles with each refusal in a row, up to an hour.
    static func backoff(afterFailures failures: Int) -> TimeInterval {
        let minutes = min(60.0, 15.0 * pow(2.0, Double(max(0, failures - 1))))
        return minutes * 60
    }

    /// A session that can never persist anything about the request.
    ///
    /// `URLSession.shared` writes responses to an on-disk cache
    /// (~/Library/Caches/<bundle id>/Cache.db), and that cache archives the
    /// *request* too -- including the Authorization header. An earlier version
    /// used it and left the bearer token on disk. Ephemeral configuration with no
    /// URLCache, no cookie storage and no credential storage keeps everything in
    /// memory. Redirects are refused so the token cannot follow one elsewhere.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }()

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static func accessToken() -> Result<String, Failure> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess: break
        case errSecItemNotFound: return .failure(.noCredential)
        // The user clicked Deny, or cancelled the password prompt.
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            return .failure(.accessDeclined)
        default: return .failure(.noCredential)
        }
        guard let data = item as? Data else { return .failure(.badCredential) }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return .failure(.badCredential) }
        return .success(token)
    }

    /// `resets_at` arrives as ISO 8601; epoch numbers are accepted too.
    private static func resetEpoch(_ any: Any?) -> Double? {
        if let n = any as? Double { return n }
        if let n = any as? Int { return Double(n) }
        guard let s = any as? String else { return nil }
        if let d = JSONPath.date(s) { return d.timeIntervalSince1970 }
        // ISO8601DateFormatter rejects microsecond precision; drop the fraction.
        let trimmed = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return JSONPath.date(trimmed)?.timeIntervalSince1970
    }
}
