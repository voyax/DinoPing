import Foundation

/// Watches transcript files for writes and calls a handler when content
/// changes. Uses `DispatchSource.makeFileSystemObjectSource` — kernel-level
/// notification with zero CPU when idle and ~10ms latency on writes.
///
/// Replaces the 5-second poll for prompt/time refresh: prompt updates are
/// now near-instant even during pure-text conversations.
public final class TranscriptWatcher: @unchecked Sendable {
    private var sources: [String: (source: DispatchSourceFileSystemObject, fd: Int32)] = [:]
    private let queue = DispatchQueue(label: "agentpulse.transcript-watcher")
    private let onChange: @Sendable () -> Void

    public init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    /// Start watching a transcript file. Safe to call multiple times for the
    /// same path — duplicates are ignored.
    public func watch(path: String) {
        queue.async { [weak self] in
            guard let self, self.sources[path] == nil else { return }
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { return }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .extend],
                queue: self.queue
            )
            source.setEventHandler { [weak self] in
                self?.onChange()
            }
            source.setCancelHandler {
                close(fd)
            }
            source.resume()
            self.sources[path] = (source, fd)
        }
    }

    /// Stop watching a specific path.
    public func unwatch(path: String) {
        queue.async { [weak self] in
            guard let entry = self?.sources.removeValue(forKey: path) else { return }
            entry.source.cancel()
        }
    }

    /// Stop watching all paths.
    public func unwatchAll() {
        queue.async { [weak self] in
            guard let self else { return }
            for (_, entry) in self.sources {
                entry.source.cancel()
            }
            self.sources.removeAll()
        }
    }

    deinit {
        for (_, entry) in sources {
            entry.source.cancel()
        }
    }
}
