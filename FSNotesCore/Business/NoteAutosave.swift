import Foundation

extension Notification.Name {
    static let workspaceFileDidChange = Notification.Name("FSNotes.workspaceFileDidChange")
}

/// One pending snapshot per note, sharing the note's lock with synchronous writes.
final class NoteAutosave {
    private let lock: NSRecursiveLock
    private var pending: NSAttributedString?
    private var scheduled = false

    init(lock: NSRecursiveLock) { self.lock = lock }

    func enqueue(_ snapshot: NSAttributedString, on queue: OperationQueue,
                 write: @escaping (NSAttributedString) -> Void,
                 didFinish: @escaping () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        pending = snapshot
        guard !scheduled else { return }
        scheduled = true
        queue.addOperation {
            while true {
                self.lock.lock()
                guard let snapshot = self.pending else {
                    self.scheduled = false
                    didFinish()
                    self.lock.unlock()
                    return
                }
                self.pending = nil
                write(snapshot)
                self.lock.unlock()
            }
        }
    }

    /// A newer synchronous write supersedes snapshots that have not been written.
    func discardPending() {
        lock.lock()
        pending = nil
        lock.unlock()
    }
}
