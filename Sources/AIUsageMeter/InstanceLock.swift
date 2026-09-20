import Foundation

/// An advisory lock that keeps two copies of the app, or the app and
/// `--scan --rebuild`, from using the cache in ways that conflict.
///
/// - The menu bar app holds it for its whole life. A second copy can't get it,
///   so it says so and quits.
/// - `--scan --rebuild` deletes the cache, so it needs the lock too and refuses
///   while the app is running.
/// - Plain `--scan` doesn't take it. Its writes are transactions and safe to run
///   alongside the app.
///
/// The OS releases the lock automatically if the process exits or crashes.
final class InstanceLock {
    private let fd: Int32

    static var lockURL: URL {
        Database.defaultURL.deletingLastPathComponent().appendingPathComponent("instance.lock")
    }

    /// Returns nil if another process holds the lock.
    init?(url: URL = InstanceLock.lockURL) {
        let fd = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        self.fd = fd
    }

    deinit {
        flock(fd, LOCK_UN)
        close(fd)
    }
}
