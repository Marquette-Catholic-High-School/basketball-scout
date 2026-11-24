import Foundation

/// `UploadManager`'s bookkeeping for one game's upload (main actor): the persisted record, the opened
/// file, the running task and why it was stopped.
final class UploadRun {
    /// Why the manager cancelled the running task.
    enum StopReason {
        case pause
        case cancel
        case suspend
        case background
        /// `removeAll()`: forget it without telling the server.
        case discard
    }

    let gameID: String
    /// Also saved in the store while the upload can still continue.
    var record: UploadRecord?
    /// The opened film; nil until prepared (a record restored after a relaunch is reopened lazily).
    var file: UploadFile?
    /// Keeps an external file readable while the run lasts.
    var access: SecurityScopedAccess?
    var task: Task<Void, Never>?
    /// Bumped by every launch: updates of an older task are ignored.
    var generation = 0
    var stopReason: StopReason?
    /// Opening the file or the bookmark (before the task starts).
    var isPreparing = false
    /// `complete` was sent: the commit point (no pause, no cancel).
    var isCompleting = false
    /// Resume was pressed while the run was still stopping after a Pause (the chunk in flight being cancelled,
    /// or the file still being opened): it continues as soon as the run has stopped.
    var resumeWhenStopped = false
    let progress = UploadProgress()
    var rate = TransferRate()

    init(gameID: String, record: UploadRecord? = nil) {
        self.gameID = gameID
        self.record = record
    }

    /// Running or about to run.
    var isBusy: Bool { task != nil || isPreparing }

    /// The relative path of the app's own copy, if the film is one.
    var copyPath: String? {
        if case .copied(let path)? = record?.source { return path }
        return nil
    }
}
