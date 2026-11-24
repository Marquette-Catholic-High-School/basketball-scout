import Foundation

/// One game's film upload as the upload screen shows it (04 §6.1 progress panel).
nonisolated struct UploadState: Identifiable, Sendable, Equatable {
    let gameID: String
    var id: String { gameID }
    /// The film's file name.
    var fileName: String
    var phase: UploadPhase
    /// Why it is paused (`phase == .paused`).
    var pauseReason: UploadPauseReason?
    /// The web's status line: "Uploading…", "Connection problem - retrying in 4 s (attempt 3 of 8)",
    /// "Finishing upload…", "Paused", "Stopped" … Show it in a polite live region.
    var statusText: String
    /// Bytes the server has plus the chunk in flight.
    var bytesSent: Int
    /// The film's size.
    var totalBytes: Int
    /// Upload speed (8-second window); nil until measured and while not sending.
    var bytesPerSecond: Double?
    /// While waiting to retry: which of the 8 attempts comes next.
    var retryAttempt: Int?
    /// The server's upload session, once there is one.
    var uploadID: String?
    /// The server's answer once finished.
    var completion: UploadCompletion?
    /// Failed or paused with the part already sent kept on the server: offer "Resume upload".
    var hasServerSession: Bool
    /// Failed because the server dropped the session (or never made one): the same file can be sent
    /// again from the start, "Upload this file again" (upload.js `SESSION_GONE`).
    var canUploadAgain: Bool

    init(
        gameID: String,
        fileName: String,
        phase: UploadPhase,
        statusText: String,
        pauseReason: UploadPauseReason? = nil,
        bytesSent: Int = 0,
        totalBytes: Int = 0,
        bytesPerSecond: Double? = nil,
        retryAttempt: Int? = nil,
        uploadID: String? = nil,
        completion: UploadCompletion? = nil,
        hasServerSession: Bool = false,
        canUploadAgain: Bool = false
    ) {
        self.gameID = gameID
        self.fileName = fileName
        self.phase = phase
        self.statusText = statusText
        self.pauseReason = pauseReason
        self.bytesSent = bytesSent
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
        self.retryAttempt = retryAttempt
        self.uploadID = uploadID
        self.completion = completion
        self.hasServerSession = hasServerSession
        self.canUploadAgain = canUploadAgain
    }

    // MARK: - For the progress panel

    /// 0…1 of the film sent.
    var fraction: Double {
        ScoutFormat.uploadFraction(sent: Int64(bytesSent), total: Int64(totalBytes))
    }

    /// "42.5%" (one decimal, counting the chunk in flight).
    var percentText: String {
        ScoutFormat.uploadPercent(sent: Int64(bytesSent), total: Int64(totalBytes))
    }

    /// "1.2 GB".
    var sizeText: String { ScoutFormat.bytes(Int64(totalBytes)) }

    /// "12.3 MB/s", or "" before there is a measurement.
    var speedText: String { ScoutFormat.transferSpeed(bytesPerSecond: bytesPerSecond) }

    /// Seconds left at the current speed.
    var secondsRemaining: Double? {
        TransferRate.secondsRemaining(remainingBytes: totalBytes - bytesSent, bytesPerSecond: bytesPerSecond)
    }

    /// "about 3 min 20 s left", or "".
    var etaText: String { ScoutFormat.eta(seconds: secondsRemaining) }

    // MARK: - Which buttons

    /// Work is going on (preparing, uploading, completing): hide the file choices and the link form.
    var isActive: Bool { phase.isActive }

    /// "Pause": while preparing or uploading; never while `complete` runs (commit point, 04 §8.9).
    var canPause: Bool {
        phase == .preparing || phase == .uploading
    }

    /// "Resume": paused, or failed with the session kept on the server.
    var canResume: Bool {
        switch phase {
        case .paused: true
        case .failed: hasServerSession
        default: false
        }
    }

    /// "Cancel upload": anything but completing, finished or cancelled.
    var canCancel: Bool {
        switch phase {
        case .preparing, .uploading, .paused, .failed: true
        case .completing, .finished, .cancelled: false
        }
    }

    static func == (lhs: UploadState, rhs: UploadState) -> Bool {
        lhs.gameID == rhs.gameID && lhs.fileName == rhs.fileName && lhs.phase == rhs.phase
            && lhs.pauseReason == rhs.pauseReason && lhs.statusText == rhs.statusText && lhs.bytesSent == rhs.bytesSent
            && lhs.totalBytes == rhs.totalBytes && lhs.bytesPerSecond == rhs.bytesPerSecond
            && lhs.retryAttempt == rhs.retryAttempt && lhs.uploadID == rhs.uploadID
            && (lhs.completion == nil) == (rhs.completion == nil) && lhs.hasServerSession == rhs.hasServerSession
            && lhs.canUploadAgain == rhs.canUploadAgain
    }
}
