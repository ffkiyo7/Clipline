import Foundation

/// Saves a file off the main thread, in order. Each save hands over the whole
/// contents; only the newest one waiting is written, so a burst of changes
/// costs one write and an older snapshot can never land after a newer one.
final class FileSaver: @unchecked Sendable {
    let url: URL
    /// Set on the file after each write, like 0o600 for something private.
    private let permissions: Int?
    private let onError: @Sendable (Error) -> Void
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var pending: Data?

    init(url: URL, permissions: Int? = nil, onError: @escaping @Sendable (Error) -> Void = { _ in }) {
        self.url = url
        self.permissions = permissions
        self.onError = onError
        queue = DispatchQueue(label: "FileSaver \(url.lastPathComponent)", qos: .utility)
    }

    func save(_ data: Data) {
        lock.lock()
        let alreadyQueued = pending != nil
        pending = data
        lock.unlock()
        if !alreadyQueued { queue.async { self.writePending() } }
    }

    /// Waits until everything saved so far is on disk. For quitting, which
    /// would otherwise drop a write still waiting its turn.
    func flush() {
        queue.sync { writePending() }
    }

    private func writePending() {
        lock.lock()
        let data = pending
        pending = nil
        lock.unlock()
        guard let data else { return }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            if let permissions {
                try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
            }
        } catch {
            onError(error)
        }
    }
}
