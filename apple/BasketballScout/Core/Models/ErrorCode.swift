import Foundation

/// The `ErrorInfo.code` values the server documents: the 44 `ErrorCode` members (01 §2.4, 09 B1; `LIVE_ENDED`
/// came with live games, docs/LIVE.md), the five
/// middleware codes (01 §2.5) and the codes the web builds on the client (01 §2.7). `ErrorInfo.code` stays a
/// plain `String` because the set is open-ended; compare it with these constants.
nonisolated enum ErrorCode {
    // GPU and film (01 §2.4)
    static let gpuOOM = "GPU_OOM"
    static let modalNotConfigured = "MODAL_NOT_CONFIGURED"
    static let modalAuthFailed = "MODAL_AUTH_FAILED"
    static let modalAppNotDeployed = "MODAL_APP_NOT_DEPLOYED"
    static let modalUploadFailed = "MODAL_UPLOAD_FAILED"
    static let modalTimeout = "MODAL_TIMEOUT"
    static let modalRemoteError = "MODAL_REMOTE_ERROR"
    static let modalResultExpired = "MODAL_RESULT_EXPIRED"
    static let videoInvalid = "VIDEO_INVALID"
    static let videoDecodeFailed = "VIDEO_DECODE_FAILED"
    static let videoTooLong = "VIDEO_TOO_LONG"
    static let videoDownloadFailed = "VIDEO_DOWNLOAD_FAILED"
    static let videoMissing = "VIDEO_MISSING"
    static let detectionFailed = "DETECTION_FAILED"
    static let ballNotDetected = "BALL_NOT_DETECTED"
    static let courtNotDetected = "COURT_NOT_DETECTED"
    static let modelLoadFailed = "MODEL_LOAD_FAILED"
    static let pipelineFailed = "PIPELINE_FAILED"
    static let trackingResultInvalid = "TRACKING_RESULT_INVALID"

    // Analysis, configuration, rosters, reports
    static let analysisFailed = "ANALYSIS_FAILED"
    static let analysisNotReady = "ANALYSIS_NOT_READY"
    static let calibrationInvalid = "CALIBRATION_INVALID"
    static let configInvalid = "CONFIG_INVALID"
    static let rosterParseFailed = "ROSTER_PARSE_FAILED"
    static let rosterUnsupportedFile = "ROSTER_UNSUPPORTED_FILE"
    static let reportNotConfigured = "REPORT_NOT_CONFIGURED"
    static let reportAuthFailed = "REPORT_AUTH_FAILED"
    static let reportRateLimited = "REPORT_RATE_LIMITED"
    static let reportOverloaded = "REPORT_OVERLOADED"
    static let reportRefused = "REPORT_REFUSED"
    static let reportTruncated = "REPORT_TRUNCATED"
    static let reportFailed = "REPORT_FAILED"

    // Uploads and requests
    static let uploadTooLarge = "UPLOAD_TOO_LARGE"
    static let uploadIncomplete = "UPLOAD_INCOMPLETE"
    static let uploadNotFound = "UPLOAD_NOT_FOUND"
    static let requestTooLarge = "REQUEST_TOO_LARGE"

    // Generic
    static let notFound = "NOT_FOUND"
    static let conflict = "CONFLICT"
    /// 409: the live game no longer takes film (ended, being finished, or its stream has ended; docs/LIVE.md).
    static let liveEnded = "LIVE_ENDED"
    static let validationFailed = "VALIDATION_FAILED"
    static let jobCancelled = "JOB_CANCELLED"
    static let workerLost = "WORKER_LOST"
    static let queueUnavailable = "QUEUE_UNAVAILABLE"
    static let internalError = "INTERNAL_ERROR"

    /// The 44 server `ErrorCode` members (09 B1 and `LIVE_ENDED`), in catalogue order.
    static let serverCodes: [String] = [
        gpuOOM, modalNotConfigured, modalAuthFailed, modalAppNotDeployed, modalUploadFailed, modalTimeout,
        modalRemoteError, modalResultExpired, videoInvalid, videoDecodeFailed, videoTooLong, videoDownloadFailed,
        videoMissing, detectionFailed, ballNotDetected, courtNotDetected, modelLoadFailed, pipelineFailed,
        trackingResultInvalid, analysisFailed, analysisNotReady, calibrationInvalid, configInvalid, rosterParseFailed,
        rosterUnsupportedFile, reportNotConfigured, reportAuthFailed, reportRateLimited, reportOverloaded,
        reportRefused, reportTruncated, reportFailed, uploadTooLarge, uploadIncomplete, uploadNotFound,
        requestTooLarge, notFound, conflict, liveEnded, validationFailed, jobCancelled, workerLost, queueUnavailable,
        internalError,
    ]

    // Middleware (01 §2.5): all retryable:false. Only AUTH_THROTTLED and AUTH_NOT_CONFIGURED make a 429 / 503
    // a sign-in problem; REPORT_RATE_LIMITED (429) and QUEUE_UNAVAILABLE (503) are ordinary app errors.
    static let authRequired = "AUTH_REQUIRED"
    static let authThrottled = "AUTH_THROTTLED"
    static let authNotConfigured = "AUTH_NOT_CONFIGURED"
    static let crossSiteRequest = "CROSS_SITE_REQUEST"
    static let hostNotAllowed = "HOST_NOT_ALLOWED"

    /// The five middleware codes (01 §2.5).
    static let middlewareCodes: [String] = [authRequired, authThrottled, authNotConfigured, crossSiteRequest, hostNotAllowed]

    // Built by the client when there is no server JSON (01 §2.7); `HTTP_<status>` for other statuses.
    static let networkError = "NETWORK_ERROR"
    static let serverUnavailable = "SERVER_UNAVAILABLE"
    static let badResponse = "BAD_RESPONSE"
    /// This app's code for a failed job that carries no `error` (`Job.failureInfo`; the web's box has none).
    static let jobFailed = "JOB_FAILED"
}
