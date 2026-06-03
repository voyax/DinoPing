import Foundation

/// Best-effort lookup for the git branch name of a given working directory.
///
/// Uses `Process` to invoke `git symbolic-ref --short HEAD` (cheap — a few
/// milliseconds on a warm cache). Results are cached per-cwd for 30s so
/// rapid card re-renders don't spawn `git` 5 times a second; the cache is
/// short enough that `git checkout` from another terminal becomes visible
/// inside a normal user-attention timeframe.
///
/// Returns `nil` for paths that aren't git repos, paths in detached-HEAD
/// state, or paths whose lookup errored (timeout, missing `git`, etc.).
@MainActor
public enum GitBranch {
    private struct Entry {
        let branch: String?
        let fetchedAt: Date
    }

    /// 30s is short enough that switching branches in another terminal
    /// becomes visible quickly, but long enough to absorb hover-driven
    /// re-renders of the same card.
    private static let cacheTTL: TimeInterval = 30

    private static var cache: [String: Entry] = [:]

    /// Synchronous cache read. Returns `nil` when there's no fresh entry —
    /// the caller should then `await refresh(cwd:)` to populate it.
    public static func cached(for cwd: String) -> String?? {
        guard let entry = cache[cwd] else { return nil }
        if Date.now.timeIntervalSince(entry.fetchedAt) > cacheTTL { return nil }
        return entry.branch
    }

    /// Run `git symbolic-ref --short HEAD` in `cwd`, populate the cache,
    /// return the branch (or nil). Safe to call repeatedly — overlapping
    /// calls just race to write the cache, which is fine since the result
    /// is the same.
    @discardableResult
    public static func refresh(cwd: String) async -> String? {
        let branch = await runGit(cwd: cwd)
        cache[cwd] = Entry(branch: branch, fetchedAt: .now)
        return branch
    }

    /// Upper bound for the `git symbolic-ref` subprocess. A healthy local
    /// repo answers in <1ms; the only thing keeping us above 0 is a
    /// pathological repo (corrupted index, network drive in a bad state,
    /// fuse/sshfs mount hanging). Kill after 2s rather than hang forever.
    nonisolated private static let subprocessTimeout: DispatchTimeInterval = .seconds(2)

    private static func runGit(cwd: String) async -> String? {
        // Off the main actor — Process I/O is blocking, would freeze UI.
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git", "-C", cwd, "symbolic-ref", "--short", "HEAD"]

            // stdout: stream into an accumulator AS the subprocess writes
            // (not after `waitUntilExit`). This is the deadlock-safe
            // pattern — if we waited until exit before draining and the
            // subprocess wrote more than ~64KB, the OS pipe buffer would
            // fill, the subprocess would block on write, and waitUntilExit
            // would deadlock. `git symbolic-ref` outputs ~20 bytes so we'd
            // never hit it in practice, but the pattern matters for any
            // future git command we add.
            let stdoutPipe = Pipe()
            let acc = StdoutAccumulator()
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    acc.append(chunk)
                }
            }
            process.standardOutput = stdoutPipe
            // stderr → /dev/null. We don't surface git's error output;
            // a non-zero termination status is enough signal.
            process.standardError = FileHandle(forWritingAtPath: "/dev/null")

            do {
                try process.run()
            } catch {
                return nil
            }

            // Timeout watchdog. `process.waitUntilExit()` is C-level
            // blocking and DOES NOT respond to Swift Task cancellation,
            // so a separate timer terminates the subprocess if it hangs.
            // Once `terminate()` fires the wait below returns with a
            // non-zero status, which we treat as "no branch".
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + subprocessTimeout)
            timer.setEventHandler {
                if process.isRunning { process.terminate() }
            }
            timer.resume()

            process.waitUntilExit()
            timer.cancel()

            guard process.terminationStatus == 0 else { return nil }

            let data = acc.snapshot()
            guard let raw = String(data: data, encoding: .utf8) else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }.value
    }
}

/// Thread-safe buffer for incremental Pipe drain. `readabilityHandler`
/// runs on Foundation's private queue, so writes from there and reads
/// from the main subprocess Task must be locked.
private final class StdoutAccumulator: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
    }

    func snapshot() -> Data {
        lock.lock(); defer { lock.unlock() }
        return data
    }
}
