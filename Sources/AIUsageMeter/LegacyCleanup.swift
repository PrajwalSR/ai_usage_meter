import Foundation

/// Removes files that earlier builds left behind and that must not stay on disk.
enum LegacyCleanup {
    /// Builds before the fix used `URLSession.shared` for the live Claude check,
    /// which cached each request, including its Authorization header, in
    /// `~/Library/Caches/local.aiusagemeter/`. Current builds never write there,
    /// so the whole folder is removed. Contents are never read or logged.
    ///
    /// Returns a short note for the panel when something was removed.
    static func removeLegacyURLCache() -> String? {
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/local.aiusagemeter")
        guard fm.fileExists(atPath: dir.path) else { return nil }
        do {
            try fm.removeItem(at: dir)
            return nil
        } catch {
            return "Couldn't remove an old request cache from an earlier version. Delete "
                + "~/Library/Caches/local.aiusagemeter yourself (see SECURITY.md)."
        }
    }

    /// Earlier builds had a backup check that saved api.anthropic.com readings to
    /// `statusline/claude-live.json`. Nothing reads that file any more, so it is
    /// removed rather than left to go stale.
    static func removeLegacyLiveReading() {
        try? FileManager.default.removeItem(
            at: ClaudeReadings.directory.appendingPathComponent("claude-live.json"))
    }

    /// Earlier builds saved every website reply, which for chatgpt.com includes
    /// the account's email and ids. Unless raw replies were asked for, any left
    /// are deleted.
    static func removeRawReplies(in dir: URL = ClaudeReadings.directory) {
        guard !WebUsageSource.saveRawReplies else { return }
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix("-raw.json") {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    /// Earlier builds created files readable by other users (0644) and the
    /// readings folder as 0755. Only the outer folder's 0700 protected them;
    /// now each file is owner-only as well.
    static func tightenPermissions(app: URL = Database.defaultURL.deletingLastPathComponent()) {
        let fm = FileManager.default
        for dir in [app, ClaudeReadings.directory] {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
                let url = dir.appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        }
    }

    /// Builds before the bundle id became `io.github.prajwalsr.aiusagemeter` kept
    /// their settings under `local.aiusagemeter`. Copied over once, on the first
    /// launch that finds no settings of its own, so nothing is switched off.
    static func migrateLegacyDefaults() {
        let old = "local.aiusagemeter"
        let defaults = UserDefaults.standard
        guard let id = Bundle.main.bundleIdentifier, id != old,
              defaults.persistentDomain(forName: id)?.isEmpty ?? true,
              let values = defaults.persistentDomain(forName: old), !values.isEmpty
        else { return }
        defaults.setPersistentDomain(values, forName: id)
    }
}
