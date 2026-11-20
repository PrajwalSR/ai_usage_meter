import Foundation

/// Turns a provider website's usage reply into a reading file.
///
/// The reply's shape isn't documented, so the parser is deliberately loose: it
/// looks for any block holding a percentage, works out which window it is from
/// its key, and keeps anything it doesn't recognise as its own limit rather than
/// dropping it. The raw reply is also saved once, so the shape can be checked.
enum WebUsageSource {
    /// How often the app may ask claude.ai. The website polls itself about this
    /// often, and this backend isn't the rate-limited one.
    static let pollInterval: TimeInterval = 60

    /// Where an account's reading and (optional) raw reply are written.
    struct Destination {
        var reading: URL
        var rawDump: URL
    }

    /// Parses the JSON from `WebSession.fetchRawUsage` and writes the reading
    /// file. Returns a description of the problem on failure.
    @discardableResult
    static func store(rawJSON: String, to destination: Destination, now: Date = Date()) -> String? {
        guard let data = rawJSON.data(using: .utf8),
              let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = top["usage"] else { return "no usage in the website's reply" }

        try? FileManager.default.createDirectory(at: ClaudeReadings.directory,
                                                 withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        // The raw reply is only for checking a new reply shape, so it is off
        // unless asked for. Even then the account's identity is removed: the
        // chatgpt.com reply carries the email and account ids.
        if saveRawReplies,
           let clean = try? JSONSerialization.data(withJSONObject: redacted(top), options: [.sortedKeys]) {
            try? clean.write(to: destination.rawDump, options: .atomic)
        }

        let windows = parseWindows(usage)
        guard !windows.isEmpty else { return "no percentages found in the website's reply" }

        var rateLimits: [String: Any] = [:]
        for (key, w) in windows {
            var entry: [String: Any] = ["used_percentage": w.usedPercent]
            if let r = w.resetsAt { entry["resets_at"] = r.timeIntervalSince1970 }
            if let m = w.windowMinutes { entry["window_minutes"] = m }
            rateLimits[key] = entry
        }
        var payload: [String: Any] = ["received_at": now.timeIntervalSince1970,
                                      "rate_limits": rateLimits]
        // chatgpt.com names the plan ("plus", "prolite") next to the limits;
        // keep it so the card can show it, as it does for Codex's logs.
        if let plan = (usage as? [String: Any])?["plan_type"] as? String, !plan.isEmpty {
            payload["plan_type"] = plan
        } else if let plan = claudePlan(top["plan"] as? [String: Any]) {
            // claude.ai names it on the organization instead.
            payload["plan_type"] = plan
        }
        // chatgpt.com: limit resets the account could use on the site. Only
        // the count is kept, for information; the reply has no expiry date.
        if let credits = (usage as? [String: Any])?["rate_limit_reset_credits"] as? [String: Any],
           let count = JSONPath.double(credits, "available_count") {
            payload["resets_available"] = Int(count)
        }
        let expiries = resetExpiries(top["resets"])
        if let soonest = expiries.first {
            payload["resets_expire_at"] = soonest.timeIntervalSince1970
            payload["resets_expire_all"] = expiries.map(\.timeIntervalSince1970)
        }
        guard let out = try? JSONSerialization.data(withJSONObject: payload),
              (try? out.write(to: destination.reading, options: .atomic)) != nil else {
            return "could not save the reading"
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: destination.reading.path)
        return nil
    }

    /// `defaults write io.github.prajwalsr.aiusagemeter saveRawReplies -bool true`
    static var saveRawReplies: Bool { UserDefaults.standard.bool(forKey: "saveRawReplies") }

    /// Keys that identify the person or account, removed at any depth.
    static let identityKeys: Set<String> = ["email", "user_id", "account_id", "org_id",
                                            "organization_id", "uuid", "name", "phone"]

    static func redacted(_ any: Any) -> Any {
        if let dict = any as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict where !identityKeys.contains(k.lowercased()) { out[k] = redacted(v) }
            return out
        }
        if let array = any as? [Any] { return array.map(redacted) }
        return any
    }

    /// Works out the Claude plan from the organization's `rate_limit_tier`
    /// (e.g. "default_claude_max_20x") and `capabilities` (e.g. "claude_max",
    /// "claude_pro"). Returns `claude_max_20x`, `claude_max_5x`, `claude_max`,
    /// `claude_pro`, `claude_team`, `claude_enterprise`, or nil when unknown.
    static func claudePlan(_ plan: [String: Any]?) -> String? {
        guard let plan else { return nil }
        let tier = (plan["tier"] as? String ?? "").lowercased()
        let caps = Set((plan["capabilities"] as? [String] ?? []).map { $0.lowercased() })
        if tier.contains("max_20x") { return "claude_max_20x" }
        if tier.contains("max_5x") { return "claude_max_5x" }
        if caps.contains("claude_max") || tier.contains("claude_max") { return "claude_max" }
        if tier.contains("enterprise") || caps.contains("claude_enterprise") { return "claude_enterprise" }
        if tier.contains("team") || caps.contains("claude_team") || caps.contains("raven") { return "claude_team" }
        if caps.contains("claude_pro") || tier.contains("claude_pro") { return "claude_pro" }
        return nil
    }

    /// Finds every block that carries a percentage, keyed by a name the reading
    /// file understands (`five_hour`, `seven_day`) or the original key.
    ///
    /// Names are matched loosely, so several blocks can claim one name:
    /// claude.ai's `seven_day_opus` next to `seven_day`, or chatgpt.com's
    /// `code_review_rate_limit.primary_window` next to
    /// `rate_limit.primary_window`. The exact key keeps the name; the others
    /// keep their own full path, so neither overwrites the other.
    static func parseWindows(_ any: Any) -> [(String, AllowanceWindow)] {
        var found: [(path: [String], window: AllowanceWindow)] = []
        walk(any, path: [], into: &found)
        let fromList = limitList(any) + additionalLimits(any)

        let groups = Dictionary(grouping: found.indices) { normalize(found[$0].path.last ?? "") }
        var result: [(String, AllowanceWindow)] = []
        for name in groups.keys.sorted() {
            let members = groups[name]!
            let owner = members.count == 1 ? members[0]
                : members.first { isExact(found[$0].path, for: name) }
            for i in members {
                var window = found[i].window
                if i == owner {
                    result.append((name, window))
                } else {
                    let own = found[i].path.joined(separator: ".")
                    window.limitId = own
                    result.append((own, window))
                }
            }
        }
        // claude.ai's `limits` list carries limits that have no block of their
        // own, such as a weekly limit for one model ("Fable"). They are kept
        // under that name; the list's session and weekly entries only fill in
        // when the reply has no `five_hour` / `seven_day` block.
        let taken = Set(result.map(\.0))
        for (name, window) in fromList where !taken.contains(name) {
            result.append((name, window))
        }
        return result
    }

    /// Expiry dates of the resets that can still be used, soonest first:
    ///
    ///     [{ "status": "available", "expires_at": "2026-12-12T22:19:24Z" }]
    static func resetExpiries(_ any: Any?, now: Date = Date()) -> [Date] {
        guard let list = any as? [[String: Any]] else { return [] }
        return list
            .filter { ($0["status"] as? String ?? "available").lowercased() == "available" }
            .compactMap { JSONPath.date($0["expires_at"]) }
            .filter { $0 > now }
            .sorted()
    }

    static func nextResetExpiry(_ any: Any?, now: Date = Date()) -> Date? {
        resetExpiries(any, now: now).first
    }

    /// Entries of claude.ai's `limits` list:
    ///
    ///     { "kind": "weekly_scoped", "group": "weekly", "percent": 1,
    ///       "resets_at": "2026-11-23T10:59:59Z",
    ///       "scope": { "model": { "display_name": "Fable" } } }
    ///
    /// `session` → `five_hour`, `weekly_all` → `seven_day`; anything else is
    /// named by its scope's display name, or by its kind.
    static func limitList(_ any: Any) -> [(String, AllowanceWindow)] {
        guard let list = (any as? [String: Any])?["limits"] as? [[String: Any]] else { return [] }
        var out: [(String, AllowanceWindow)] = []
        for entry in list {
            guard let percent = JSONPath.double(entry, "percent") ?? percentage(in: entry) else { continue }
            let kind = (entry["kind"] as? String ?? "").lowercased()
            let group = (entry["group"] as? String ?? "").lowercased()
            let scope = entry["scope"] as? [String: Any]
            let scopeName = ["model", "surface"].lazy
                .compactMap { (scope?[$0] as? [String: Any])?["display_name"] as? String }
                .first { !$0.isEmpty }
            let name: String
            switch kind {
            case "session": name = "five_hour"
            case "weekly_all": name = "seven_day"
            default: name = scopeName ?? (kind.isEmpty ? "limit" : kind)
            }
            let minutes: Int? = switch group {
            case "session": 300
            case "weekly": 10080
            default: name == "five_hour" ? 300 : name == "seven_day" ? 10080 : nil
            }
            let resets = resetDate(in: entry)
            guard minutes != nil || resets != nil, !out.contains(where: { $0.0 == name }) else { continue }
            out.append((name, AllowanceWindow(usedPercent: percent, windowMinutes: minutes, resetsAt: resets,
                                              limitId: knownNames.contains(name) ? nil : name)))
        }
        return out
    }

    /// chatgpt.com's `additional_rate_limits`, a list of named limits each with
    /// its own windows (the shape Codex itself reads; not yet seen filled in):
    ///
    ///     [{ "limit_name": "codex_other", "metered_feature": "…",
    ///        "rate_limit": { "primary_window": { "used_percent": 12, … },
    ///                        "secondary_window": null } }]
    static func additionalLimits(_ any: Any) -> [(String, AllowanceWindow)] {
        guard let list = (any as? [String: Any])?["additional_rate_limits"] as? [[String: Any]] else { return [] }
        var out: [(String, AllowanceWindow)] = []
        for entry in list {
            let name = [entry["limit_name"], entry["metered_feature"]].lazy
                .compactMap { $0 as? String }.first { !$0.isEmpty } ?? "additional"
            let windows = parseWindows(entry["rate_limit"] ?? entry)
                .filter { !$0.0.contains(".") || rankNames.contains(String($0.0.split(separator: ".").last ?? "")) }
            for (i, (_, w)) in windows.enumerated() {
                let id = windows.count > 1 && i > 0 ? "\(name) (\(w.windowLabel))" : name
                guard !out.contains(where: { $0.0 == id }) else { continue }
                var window = w
                window.limitId = id
                out.append((id, window))
            }
        }
        return out
    }

    /// `five_hour`, `seven_day`, or a rank window directly under the main
    /// `rate_limit(s)` block.
    private static func isExact(_ path: [String], for name: String) -> Bool {
        guard let key = path.last?.lowercased() else { return false }
        if key == name { return path.count <= 2 }
        guard rankNames.contains(name), key == name + "_window" else { return false }
        let parent = path.dropLast().last?.lowercased()
        return parent == nil || parent == "rate_limit" || parent == "rate_limits"
    }

    private static func walk(_ any: Any, path: [String],
                             into found: inout [(path: [String], window: AllowanceWindow)]) {
        guard let dict = any as? [String: Any] else { return }

        if let key = path.last, let percent = percentage(in: dict) {
            let name = normalize(key)
            let minutes = windowMinutes(for: key, dict: dict)
            let resets = resetDate(in: dict)
            // claude.ai's reply carries internal entries (code names like
            // "nimbus_quill") that are 0% with no window and no reset. They are
            // not usage limits, so only keep a window we can name, or one that
            // says when it resets.
            let isRealWindow = minutes != nil || resets != nil
            if isRealWindow {
                found.append((path, AllowanceWindow(
                    usedPercent: percent,
                    windowMinutes: minutes,
                    resetsAt: resets,
                    limitId: (knownNames.union(rankNames)).contains(name) ? nil : name)))
            }
            return                                   // don't descend into a window
        }
        // Sorted, so the result doesn't depend on dictionary order.
        for k in dict.keys.sorted() { walk(dict[k]!, path: path + [k], into: &found) }
    }

    private static let knownNames: Set<String> = ["five_hour", "seven_day"]

    private static func percentage(in dict: [String: Any]) -> Double? {
        for name in ["utilization", "used_percentage", "used_percent", "percent_used", "percentage"] {
            if let v = JSONPath.double(dict, name) { return v }
        }
        return nil
    }

    private static func resetDate(in dict: [String: Any], now: Date = Date()) -> Date? {
        for name in ["resets_at", "reset_at", "resets", "next_reset"] {
            if let n = JSONPath.double(dict, name) { return Date(timeIntervalSince1970: n) }
            if let d = JSONPath.date(dict[name]) { return d }
        }
        // chatgpt.com reports some windows as "seconds from now" instead.
        for name in ["resets_in_seconds", "reset_after_seconds", "seconds_until_reset"] {
            // (reset_at is preferred above; these are the "seconds from now" forms)
            if let n = JSONPath.double(dict, name) { return now.addingTimeInterval(n) }
        }
        return nil
    }

    /// claude.ai names windows differently from the status line, so map the
    /// familiar ones and leave the rest under their own name.
    private static func normalize(_ key: String) -> String {
        let k = key.lowercased()
        if k.contains("five") || k.contains("5h") || k.contains("session") { return "five_hour" }
        if k.contains("seven") || k.contains("7d") || k.contains("week") { return "seven_day" }
        // chatgpt.com names its windows by rank ("primary_window"), not by
        // length. The length comes from the same block, and a rank is not a
        // limit name, so it is not shown as one.
        if k.hasPrefix("primary") { return "primary" }
        if k.hasPrefix("secondary") { return "secondary" }
        return key
    }

    /// Rank names, which should not be displayed as a limit id.
    static let rankNames: Set<String> = ["primary", "secondary"]

    private static func windowMinutes(for key: String, dict: [String: Any]) -> Int? {
        if let m = JSONPath.double(dict, "window_minutes") { return Int(m) }
        // chatgpt.com reports the length in seconds instead.
        for name in ["limit_window_seconds", "window_seconds"] {
            if let s = JSONPath.double(dict, name), s > 0 { return Int(s / 60) }
        }
        switch normalize(key) {
        case "five_hour": return 300
        case "seven_day": return 10080
        default: return nil
        }
    }
}
