"""Film playback and manual court calibration.

Video is served with ``FileResponse``, which answers HTTP Range requests (206), so the
browser's ``<video>`` element can seek through a multi-GB film.
"""

from __future__ import annotations

import logging
from typing import Literal

from fastapi import APIRouter
from fastapi.responses import FileResponse, Response

from scout import db, storage
from scout.analysis import geometry
from scout.api.deps import CurrentGame, SettingsDep
from scout.api.models import CalibrationRequest
from scout.errors import ErrorCode, ScoutError
from scout.schemas import CourtCalibration, Game

logger = logging.getLogger(__name__)

MIN_CALIBRATION_POINTS = 4

router = APIRouter(tags=["media"])


@router.get("/games/{game_id}/video")
def get_video(
    game: CurrentGame, variant: Literal["original", "annotated"] = "original", download: bool = False
) -> FileResponse:
    path = storage.annotated_video_path(game.id) if variant == "annotated" else storage.find_source_video(game.id)
    if path is None or not path.is_file():
        raise _video_missing(game, variant)
    filename = f"{game.id}_{variant}{path.suffix}"
    # Served as video/mp4 even for .mov: browsers play H.264 QuickTime files that way.
    # no-cache: the URL stays the same when the film is replaced or re-analysed, so the
    # browser must check the ETag (If-Range) instead of replaying a cached old film.
    return FileResponse(
        path,
        media_type="video/mp4",
        filename=filename if download else None,
        content_disposition_type="attachment",
        headers={"Cache-Control": "no-cache"},
    )


def _video_missing(game: Game, variant: str) -> ScoutError:
    if variant == "annotated":
        return ScoutError(
            ErrorCode.NOT_FOUND,
            "The annotated video is not available for this game.",
            hint="It is created when the analysis finishes (if SCOUT_RENDER_ANNOTATED_VIDEO is on).",
        )
    if game.video_url:
        return ScoutError(
            ErrorCode.NOT_FOUND,
            "This game's film was added as a link, so it is not stored on this server.",
            hint=f"Open the original link instead: {game.video_url}",
        )
    return ScoutError(ErrorCode.NOT_FOUND, "No film has been uploaded for this game yet.", hint="Upload an MP4 first.")


@router.put("/games/{game_id}/calibration", response_model=CourtCalibration)
def set_calibration(body: CalibrationRequest, game: CurrentGame, settings: SettingsDep) -> CourtCalibration:
    """Pixel -> court-feet homography from landmarks the coach clicked on a still frame."""
    known = geometry.landmarks(geometry.load_court_config(settings.court_config))
    names = [point.landmark for point in body.points]
    unknown = sorted({name for name in names if name not in known})
    if unknown:
        raise ScoutError(ErrorCode.CALIBRATION_INVALID, f"Unknown court landmark(s): {', '.join(unknown)}.")
    if len(set(names)) != len(names):
        raise ScoutError(ErrorCode.CALIBRATION_INVALID, "Each court landmark can only be clicked once.")
    if len(names) < MIN_CALIBRATION_POINTS:
        raise ScoutError(
            ErrorCode.CALIBRATION_INVALID, f"Click at least {MIN_CALIBRATION_POINTS} landmarks; got {len(names)}."
        )
    try:
        matrix, error_ft = geometry.compute_homography([p.px for p in body.points], [known[n] for n in names])
    except ValueError as exc:
        raise ScoutError(ErrorCode.CALIBRATION_INVALID, detail=str(exc)) from exc
    calibration = CourtCalibration(
        points=body.points,
        matrix=matrix,
        reprojection_error_ft=round(error_ft, 3),
        frame_t=body.frame_t,
        video_width=body.video_width,
        video_height=body.video_height,
        created_at=db.utcnow(),
    )
    db.update_game(game.id, calibration=calibration)
    logger.info("Game %s calibrated from %d points (mean error %.2f ft)", game.id, len(names), error_ft)
    return calibration


@router.delete("/games/{game_id}/calibration", status_code=204)
def delete_calibration(game: CurrentGame) -> Response:
    db.update_game(game.id, calibration=None)
    return Response(status_code=204)
