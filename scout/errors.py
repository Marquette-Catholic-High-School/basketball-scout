"""Error taxonomy.

Every failure a coach can see carries a stable ``ErrorCode``, a short title, a plain
English message and a hint about what to do next. Raise ``ScoutError`` anywhere in
the server; the API layer and the worker turn it into an ``ErrorInfo``.

The Modal pipeline returns the same code strings (see ``modal_app/pipeline/errors.py``)
so GPU-side failures map onto these entries via ``ScoutError.from_code``.
"""

from __future__ import annotations

from enum import StrEnum

from scout.schemas import ErrorInfo


class ErrorCode(StrEnum):
    # GPU / Modal
    GPU_OOM = "GPU_OOM"
    MODAL_NOT_CONFIGURED = "MODAL_NOT_CONFIGURED"
    MODAL_AUTH_FAILED = "MODAL_AUTH_FAILED"
    MODAL_APP_NOT_DEPLOYED = "MODAL_APP_NOT_DEPLOYED"
    MODAL_UPLOAD_FAILED = "MODAL_UPLOAD_FAILED"
    MODAL_TIMEOUT = "MODAL_TIMEOUT"
    MODAL_REMOTE_ERROR = "MODAL_REMOTE_ERROR"
    MODAL_RESULT_EXPIRED = "MODAL_RESULT_EXPIRED"
    # Video
    VIDEO_INVALID = "VIDEO_INVALID"
    VIDEO_DECODE_FAILED = "VIDEO_DECODE_FAILED"
    VIDEO_TOO_LONG = "VIDEO_TOO_LONG"
    VIDEO_DOWNLOAD_FAILED = "VIDEO_DOWNLOAD_FAILED"
    VIDEO_MISSING = "VIDEO_MISSING"
    # Detection / perception
    DETECTION_FAILED = "DETECTION_FAILED"
    BALL_NOT_DETECTED = "BALL_NOT_DETECTED"
    COURT_NOT_DETECTED = "COURT_NOT_DETECTED"
    MODEL_LOAD_FAILED = "MODEL_LOAD_FAILED"
    PIPELINE_FAILED = "PIPELINE_FAILED"
    # Server-side analysis
    TRACKING_RESULT_INVALID = "TRACKING_RESULT_INVALID"
    ANALYSIS_FAILED = "ANALYSIS_FAILED"
    ANALYSIS_NOT_READY = "ANALYSIS_NOT_READY"
    CALIBRATION_INVALID = "CALIBRATION_INVALID"
    CONFIG_INVALID = "CONFIG_INVALID"
    # Roster
    ROSTER_PARSE_FAILED = "ROSTER_PARSE_FAILED"
    ROSTER_UNSUPPORTED_FILE = "ROSTER_UNSUPPORTED_FILE"
    # Claude report
    REPORT_NOT_CONFIGURED = "REPORT_NOT_CONFIGURED"
    REPORT_AUTH_FAILED = "REPORT_AUTH_FAILED"
    REPORT_RATE_LIMITED = "REPORT_RATE_LIMITED"
    REPORT_OVERLOADED = "REPORT_OVERLOADED"
    REPORT_REFUSED = "REPORT_REFUSED"
    REPORT_TRUNCATED = "REPORT_TRUNCATED"
    REPORT_FAILED = "REPORT_FAILED"
    # Uploads / API
    UPLOAD_TOO_LARGE = "UPLOAD_TOO_LARGE"
    UPLOAD_INCOMPLETE = "UPLOAD_INCOMPLETE"
    UPLOAD_NOT_FOUND = "UPLOAD_NOT_FOUND"
    REQUEST_TOO_LARGE = "REQUEST_TOO_LARGE"
    NOT_FOUND = "NOT_FOUND"
    CONFLICT = "CONFLICT"
    VALIDATION_FAILED = "VALIDATION_FAILED"
    # Jobs / misc
    JOB_CANCELLED = "JOB_CANCELLED"
    WORKER_LOST = "WORKER_LOST"
    QUEUE_UNAVAILABLE = "QUEUE_UNAVAILABLE"
    INTERNAL_ERROR = "INTERNAL_ERROR"


# code -> (title, default message, hint, retryable, http_status)
_CATALOG: dict[ErrorCode, tuple[str, str, str | None, bool, int]] = {
    ErrorCode.GPU_OOM: (
        "GPU ran out of memory",
        "The GPU ran out of memory while processing the film, even after retrying with smaller batches.",
        "Retry the job. If it keeps failing, lower SCOUT_ANALYSIS_FPS or SCOUT_ANALYSIS_MAX_SIDE in .env, or trim the video.",
        True,
        507,
    ),
    ErrorCode.MODAL_NOT_CONFIGURED: (
        "Modal is not configured",
        "No Modal credentials were found, so the film cannot be sent to the GPU.",
        "Run `modal token new` (or set MODAL_TOKEN_ID / MODAL_TOKEN_SECRET in .env) and restart the worker. "
        "For a UI demo without a GPU set SCOUT_PROCESSOR=mock.",
        False,
        503,
    ),
    ErrorCode.MODAL_AUTH_FAILED: (
        "Modal rejected the credentials",
        "Modal refused the configured token.",
        "Create a fresh token with `modal token new` and update .env.",
        False,
        503,
    ),
    ErrorCode.MODAL_APP_NOT_DEPLOYED: (
        "GPU app is not deployed",
        "The Modal app/function could not be found.",
        "Deploy it with `modal deploy modal_app/app.py` (or `scripts/update.sh --deploy-modal`).",
        False,
        503,
    ),
    ErrorCode.MODAL_UPLOAD_FAILED: (
        "Upload to the GPU service failed",
        "The film could not be copied to the Modal volume.",
        "Check the server's internet connection and retry.",
        True,
        502,
    ),
    ErrorCode.MODAL_TIMEOUT: (
        "GPU processing timed out",
        "Processing took longer than the configured time limit.",
        "Retry. For very long films raise SCOUT_MODAL_TIMEOUT_S (and SCOUT_MODAL_MAX_WAIT_HOURS) in .env, "
        "redeploy with `scripts/update.sh --deploy-modal`, or split the film.",
        True,
        504,
    ),
    ErrorCode.MODAL_REMOTE_ERROR: (
        "GPU processing failed",
        "The GPU job crashed unexpectedly.",
        "Retry the job. Check `modal app logs basketball-scout` for details.",
        True,
        502,
    ),
    ErrorCode.MODAL_RESULT_EXPIRED: (
        "GPU result expired",
        "The GPU job finished but its result is no longer available.",
        "Re-run the analysis.",
        True,
        410,
    ),
    ErrorCode.VIDEO_INVALID: (
        "Not a usable video",
        "The file does not look like an MP4/MOV video.",
        "Export the film as H.264 MP4 (Hudl: Download > MP4) and upload again.",
        False,
        422,
    ),
    ErrorCode.VIDEO_DECODE_FAILED: (
        "Video could not be decoded",
        "The video file is corrupt or uses an unsupported codec.",
        "Re-export as H.264 MP4 and upload again.",
        False,
        422,
    ),
    ErrorCode.VIDEO_TOO_LONG: (
        "Video is too long",
        "The film is longer than the configured maximum duration.",
        "Trim the film or raise SCOUT_MAX_VIDEO_MINUTES.",
        False,
        422,
    ),
    ErrorCode.VIDEO_DOWNLOAD_FAILED: (
        "Video download failed",
        "The GPU worker could not download the film from the provided URL.",
        "Make sure the link is a direct, publicly reachable MP4 link (not a web page), or upload the file instead.",
        True,
        502,
    ),
    ErrorCode.VIDEO_MISSING: (
        "No video",
        "This game has no film yet.",
        "Upload an MP4 or provide a video URL first.",
        False,
        409,
    ),
    ErrorCode.DETECTION_FAILED: (
        "Players could not be detected",
        "Too few players were detected for a reliable analysis.",
        "Use a wide game-film angle that shows the whole court (not a close-up or highlight reel).",
        False,
        422,
    ),
    ErrorCode.BALL_NOT_DETECTED: (
        "Ball tracking failed",
        "The basketball was found in too few frames to detect shots and possessions.",
        "Higher-resolution film (720p+) helps. Box score numbers may be incomplete.",
        False,
        422,
    ),
    ErrorCode.COURT_NOT_DETECTED: (
        "Court lines not found",
        "The court could not be mapped, so shot zones are approximate.",
        "Calibrate the court manually on the game page (fixed cameras only) and re-run the analysis.",
        False,
        422,
    ),
    ErrorCode.MODEL_LOAD_FAILED: (
        "Model weights failed to load",
        "A detection/pose/OCR model could not be loaded on the GPU worker.",
        "Redeploy the Modal app; check custom weight paths in .env.",
        True,
        502,
    ),
    ErrorCode.PIPELINE_FAILED: (
        "Video pipeline failed",
        "The computer-vision pipeline stopped with an error.",
        "Retry. If it persists, check `modal app logs basketball-scout`.",
        True,
        502,
    ),
    ErrorCode.TRACKING_RESULT_INVALID: (
        "Unexpected GPU output",
        "The GPU result did not match the expected tracking schema.",
        "Make sure the deployed Modal app matches this server version (`scripts/update.sh --deploy-modal`).",
        False,
        502,
    ),
    ErrorCode.ANALYSIS_FAILED: (
        "Analysis failed",
        "Building the box score / play breakdown failed.",
        "Retry 'Re-run analysis'. If it persists, report the job id.",
        True,
        500,
    ),
    ErrorCode.ANALYSIS_NOT_READY: (
        "Analysis not ready",
        "This game has not been analysed yet.",
        "Wait for the processing job to finish.",
        False,
        409,
    ),
    ErrorCode.CALIBRATION_INVALID: (
        "Court calibration rejected",
        "The clicked court points do not produce a usable mapping.",
        "Click at least 4 landmarks spread across the court, not all on one line.",
        False,
        422,
    ),
    ErrorCode.CONFIG_INVALID: (
        "Settings file is invalid",
        "A settings file under config/ could not be used.",
        "Fix the setting named in the message, or ask IT to restore the shipped file (README.md > Troubleshooting > CONFIG_INVALID).",
        False,
        500,
    ),
    ErrorCode.ROSTER_PARSE_FAILED: (
        "Roster could not be read",
        "No players could be read from the roster file.",
        "Use a CSV/XLSX with a header row containing a jersey number column (#, No, Number) and a name column.",
        False,
        422,
    ),
    ErrorCode.ROSTER_UNSUPPORTED_FILE: (
        "Unsupported roster file",
        "Only .csv, .tsv, .txt and .xlsx roster files are supported.",
        "Save the roster as CSV or Excel (.xlsx).",
        False,
        415,
    ),
    ErrorCode.REPORT_NOT_CONFIGURED: (
        "Claude is not configured",
        "No Anthropic API key is set, so the scouting report cannot be written.",
        "Add ANTHROPIC_API_KEY to .env and restart the worker.",
        False,
        503,
    ),
    ErrorCode.REPORT_AUTH_FAILED: (
        "Anthropic refused the request",
        "The Anthropic API key was rejected.",
        "Check ANTHROPIC_API_KEY in .env.",
        False,
        503,
    ),
    ErrorCode.REPORT_RATE_LIMITED: (
        "Claude rate limit reached",
        "The Anthropic API is rate limiting this key.",
        "Wait a minute and click 'Generate report' again.",
        True,
        429,
    ),
    ErrorCode.REPORT_OVERLOADED: (
        "Claude is busy",
        "The Anthropic API is temporarily overloaded.",
        "Try again in a few minutes.",
        True,
        503,
    ),
    ErrorCode.REPORT_REFUSED: (
        "Claude declined the request",
        "The model declined to write this report.",
        "Remove unusual instructions from the coach focus box and try again.",
        False,
        422,
    ),
    ErrorCode.REPORT_TRUNCATED: (
        "Report was cut off",
        "The report hit the output token limit before it finished.",
        "Raise SCOUT_CLAUDE_MAX_TOKENS in .env and regenerate.",
        True,
        502,
    ),
    ErrorCode.REPORT_FAILED: (
        "Report generation failed",
        "Writing the scouting report failed.",
        "Try again. Stats and exports are still available.",
        True,
        502,
    ),
    ErrorCode.UPLOAD_TOO_LARGE: (
        "File too large",
        "The video is larger than the configured upload limit.",
        "Raise SCOUT_MAX_UPLOAD_GB in .env or compress/trim the film.",
        False,
        413,
    ),
    ErrorCode.UPLOAD_INCOMPLETE: (
        "Upload incomplete",
        "Not all of the file arrived.",
        "Retry the upload; it resumes where it stopped.",
        True,
        409,
    ),
    ErrorCode.UPLOAD_NOT_FOUND: (
        "Upload not found",
        "That upload session does not exist or has expired.",
        "Start the upload again.",
        False,
        404,
    ),
    ErrorCode.REQUEST_TOO_LARGE: (
        "Request too large",
        "The request was larger than this server accepts.",
        "Send film with the upload page; roster files must be under 2 MB.",
        False,
        413,
    ),
    ErrorCode.NOT_FOUND: ("Not found", "The requested item does not exist.", None, False, 404),
    ErrorCode.CONFLICT: ("Conflict", "The request conflicts with the current state.", None, False, 409),
    ErrorCode.VALIDATION_FAILED: ("Invalid input", "Some fields are invalid.", None, False, 422),
    ErrorCode.JOB_CANCELLED: ("Cancelled", "The job was cancelled.", None, False, 409),
    ErrorCode.WORKER_LOST: (
        "Worker stopped",
        "The background worker stopped while running this job too many times.",
        "Check `journalctl -u basketball-scout-worker` and retry.",
        True,
        500,
    ),
    ErrorCode.QUEUE_UNAVAILABLE: (
        "Job queue unavailable",
        "The job queue (Redis) could not be reached.",
        "Start Redis (`sudo systemctl start redis-server`) or set SCOUT_QUEUE_BACKEND=sqlite.",
        True,
        503,
    ),
    ErrorCode.INTERNAL_ERROR: (
        "Unexpected error",
        "Something went wrong on the server.",
        "Retry; if it keeps happening check the server logs.",
        True,
        500,
    ),
}


def http_status_for(code: ErrorCode | str) -> int:
    try:
        return _CATALOG[ErrorCode(code)][4]
    except (ValueError, KeyError):
        return 500


class ScoutError(Exception):
    """An error with a stable code and a user-facing explanation."""

    def __init__(
        self,
        code: ErrorCode | str,
        message: str | None = None,
        *,
        hint: str | None = None,
        detail: str | None = None,
        retryable: bool | None = None,
    ) -> None:
        try:
            self.code = ErrorCode(code)
        except ValueError:
            self.code = ErrorCode.INTERNAL_ERROR
            detail = f"unknown error code {code!r}" + (f": {detail}" if detail else "")
        title, default_message, default_hint, default_retryable, status = _CATALOG[self.code]
        self.title = title
        self.message = message or default_message
        self.hint = hint if hint is not None else default_hint
        self.detail = detail
        self.retryable = default_retryable if retryable is None else retryable
        self.http_status = status
        super().__init__(f"{self.code}: {self.message}")

    @classmethod
    def from_code(cls, code: str, message: str | None = None, detail: str | None = None) -> ScoutError:
        """Build from a code string coming from the Modal pipeline (unknown codes -> PIPELINE_FAILED)."""
        try:
            known = ErrorCode(code)
        except ValueError:
            return cls(ErrorCode.PIPELINE_FAILED, message, detail=f"[{code}] {detail or ''}".strip())
        return cls(known, message, detail=detail)

    def to_info(self) -> ErrorInfo:
        return ErrorInfo(
            code=str(self.code),
            title=self.title,
            message=self.message,
            hint=self.hint,
            retryable=self.retryable,
            detail=self.detail,
        )


def error_info(code: ErrorCode | str, message: str | None = None, **kwargs: object) -> ErrorInfo:
    return ScoutError(code, message, **kwargs).to_info()  # type: ignore[arg-type]
