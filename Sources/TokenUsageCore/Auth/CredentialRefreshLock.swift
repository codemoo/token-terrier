import Darwin
import Foundation

// Darwin's `flock` symbol is ambiguous in Swift — there's a C `struct flock`
// (used by `fcntl`) with the same name as the BSD syscall. Importing it as
// a renamed function via `@_silgen_name` disambiguates by linker symbol.
@_silgen_name("flock")
private func sysFlock(_ fd: Int32, _ operation: Int32) -> Int32

/// Cross-process advisory lock used to serialize OAuth refreshes.
///
/// Multiple TokenTerrier processes (the menubar app's `LocalDirectClient` and the
/// `token-usage-daemon`, and possibly a future CLI helper) can hold the same
/// credential file open at once. Without coordination they may race a refresh:
/// one process spends the (often single-use) refresh token, the other tries to
/// reuse it and gets HTTP 401, and the user sees a false "logged out" state.
///
/// This is a non-blocking flock with cooperative polling — we don't park the
/// Swift cooperative executor on a long blocking syscall, and the wait honors
/// `Task.cancellation` and a configurable timeout.
///
/// Note: `flock` is advisory. It only protects callers who use the same
/// `lock` file. Claude / Codex CLIs don't share this lock, so a refresh race
/// with them is still possible — but those external writers tend to be
/// short-lived and we further mitigate by re-reading disk inside the lock.
public struct CredentialRefreshLock: Sendable {
    public let url: URL
    public let timeout: TimeInterval
    public let pollInterval: Duration

    public init(
        url: URL,
        timeout: TimeInterval = 45,
        pollInterval: Duration = .milliseconds(50))
    {
        self.url = url
        self.timeout = timeout
        self.pollInterval = pollInterval
    }

    /// Default lock for the given provider, sitting next to the credential
    /// file it protects.
    public static func `default`(for provider: Provider) -> CredentialRefreshLock {
        CredentialRefreshLock(url: CredentialFiles.credentialLockURL(for: provider))
    }

    /// Acquires the lock for the duration of `body`. The lock is released
    /// (and the fd closed) even on error.
    public func withLock<T>(_ body: () async throws -> T) async throws -> T {
        let handle = try await acquire()
        defer { try? handle.unlock() }
        return try await body()
    }

    /// Acquires the lock and returns a handle. Caller is responsible for
    /// calling `unlock()` (or relying on `deinit`).
    public func acquire() async throws -> Handle {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        let fd = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw CredentialLockError.openFailed(url.path, errno) }

        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if sysFlock(fd, LOCK_EX | LOCK_NB) == 0 {
                return Handle(fd: fd, url: url)
            }
            let code = errno
            if code == EINTR { continue }
            if code == EWOULDBLOCK || code == EAGAIN {
                if Date() >= deadline {
                    Darwin.close(fd)
                    throw CredentialLockError.timeout(url.path, timeout)
                }
                do {
                    try Task.checkCancellation()
                    try await Task.sleep(for: pollInterval)
                } catch {
                    Darwin.close(fd)
                    throw error
                }
                continue
            }
            Darwin.close(fd)
            throw CredentialLockError.lockFailed(url.path, code)
        }
    }

    public final class Handle: @unchecked Sendable {
        private let fd: Int32
        private let url: URL
        private let mutex = NSLock()
        private var closed = false

        fileprivate init(fd: Int32, url: URL) {
            self.fd = fd
            self.url = url
        }

        deinit { try? unlock() }

        /// Releases the flock and closes the fd. Idempotent.
        public func unlock() throws {
            mutex.lock()
            defer { mutex.unlock() }
            guard !closed else { return }
            let unlockResult = sysFlock(fd, LOCK_UN)
            let closeResult = Darwin.close(fd)
            closed = true
            if unlockResult != 0 { throw CredentialLockError.unlockFailed(url.path, errno) }
            if closeResult != 0 { throw CredentialLockError.closeFailed(url.path, errno) }
        }
    }
}

public enum CredentialLockError: LocalizedError, Equatable, Sendable {
    case openFailed(String, Int32)
    case lockFailed(String, Int32)
    case unlockFailed(String, Int32)
    case closeFailed(String, Int32)
    case timeout(String, TimeInterval)

    public var errorDescription: String? {
        switch self {
        case let .openFailed(path, code):
            return "Failed to open credential lock at \(path): errno=\(code)"
        case let .lockFailed(path, code):
            return "Failed to acquire credential lock at \(path): errno=\(code)"
        case let .unlockFailed(path, code):
            return "Failed to release credential lock at \(path): errno=\(code)"
        case let .closeFailed(path, code):
            return "Failed to close credential lock at \(path): errno=\(code)"
        case let .timeout(path, seconds):
            return "Timed out after \(seconds)s waiting for credential lock at \(path)"
        }
    }
}
