"""Pipeline error codes. Kept in sync with ``scout.errors.ErrorCode`` (same strings)."""

from __future__ import annotations

GPU_OOM = "GPU_OOM"
VIDEO_INVALID = "VIDEO_INVALID"
VIDEO_DECODE_FAILED = "VIDEO_DECODE_FAILED"
VIDEO_TOO_LONG = "VIDEO_TOO_LONG"
VIDEO_DOWNLOAD_FAILED = "VIDEO_DOWNLOAD_FAILED"
DETECTION_FAILED = "DETECTION_FAILED"
BALL_NOT_DETECTED = "BALL_NOT_DETECTED"
COURT_NOT_DETECTED = "COURT_NOT_DETECTED"
MODEL_LOAD_FAILED = "MODEL_LOAD_FAILED"
PIPELINE_FAILED = "PIPELINE_FAILED"


class PipelineError(Exception):
    """Expected failure with a code the server understands (see scout/errors.py)."""

    def __init__(self, code: str, message: str, detail: str | None = None) -> None:
        super().__init__(f"{code}: {message}")
        self.code = code
        self.message = message
        self.detail = detail

    def to_dict(self) -> dict[str, str | None]:
        return {"code": self.code, "message": self.message, "detail": self.detail}


def is_cuda_oom(exc: BaseException) -> bool:
    """True for torch.cuda.OutOfMemoryError and ONNX Runtime / cuDNN allocation failures."""
    name = type(exc).__name__
    text = str(exc).lower()
    return name == "OutOfMemoryError" or "out of memory" in text or "cudaerrormemoryallocation" in text or (
        "failed to allocate memory" in text and "cuda" in text
    )
