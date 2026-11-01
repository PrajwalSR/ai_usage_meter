import Foundation

/// Watches log directories with FSEvents and reports changes after a quiet
/// period, so a burst of writes during an active turn triggers one rescan.
final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "io.github.prajwalsr.aiusagemeter.fsevents")
    private let debounce: TimeInterval
    private var pending: DispatchWorkItem?
    private let onChange: () -> Void

    init(paths: [String], debounce: TimeInterval = 2.0, onChange: @escaping () -> Void) {
        self.debounce = debounce
        self.onChange = onChange

        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue().schedule()
        }

        stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            existing as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))

        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    var isWatching: Bool { stream != nil }

    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
