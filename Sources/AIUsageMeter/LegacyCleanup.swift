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
}
