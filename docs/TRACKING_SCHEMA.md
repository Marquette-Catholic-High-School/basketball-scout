# Tracking contract (GPU pipeline ⇄ server)

This is the contract between the GPU pipeline (`modal_app/`, running on Modal or
locally) and the server-side transform (`scout/analysis/`). The pydantic models in
`scout/schemas.py` (`TrackingResult` and friends) are the source of truth; this page
explains the semantics.

## Conventions

* `frame` / `f`: 0-based frame number in the ORIGINAL video; `t = frame / video.fps`.
* Tracks are sampled at `video.analysis_fps` (every `round(fps / analysis_fps)` frames).
* Pixel coordinates: ORIGINAL video resolution (`video.width` × `video.height`), even
  if the pipeline analysed a downscaled copy.
* Court coordinates: feet. Origin at the corner where the LEFT baseline (as seen by
  the camera) meets the NEAR sideline (camera side). `x` ∈ [0, length_ft] along the
  court, `y` ∈ [0, width_ft] across it. Baskets at `(5.25, 25)` and `(length-5.25, 25)`
  for a 50 ft wide court.
* Team ids (`team_id`) are pipeline clusters (0, 1). The server maps them to
  `scouted` / `other` using the game's colour hint or the coach's choice.

## Processing request / response

The worker calls the processor (Modal function `process_video`, or the local runner)
with one dict:

```json
{
  "job_id": "j_abc123",
  "video": {"type": "volume", "path": "uploads/j_abc123/source.mp4", "filename": "vs-central.mp4"},
  "output_dir": "results/j_abc123",
  "options": {
    "analysis_fps": 10,
    "analysis_max_side": 1280,
    "render_video": true,
    "render_height": 720,
    "max_duration_s": 9000,
    "court_length_ft": 84,
    "court_width_ft": 50,
    "calibration": {"matrix": [[...],[...],[...]], "video_width": 1920, "video_height": 1080},
    "detector_weights": null,
    "court_keypoint_weights": null,
    "scouted_color_hint": "dark"
  }
}
```

`video` may instead be `{"type": "url", "url": "https://.../film.mp4", "filename": "film.mp4"}`;
the pipeline downloads it. Paths are relative to the Modal volume root (mounted at
`/data` in the container) or, for the local processor, to its working directory.

`calibration` (optional) is a manual pixel→court homography for a FIXED camera,
made by clicking court landmarks in the UI. When present and the pipeline has no
court-keypoint model output for a frame, it projects with this matrix.

Success response:

```json
{
  "status": "ok",
  "job_id": "j_abc123",
  "tracking_path": "results/j_abc123/tracking.json.gz",
  "annotated_video_path": "results/j_abc123/annotated.mp4",
  "summary": {"duration_s": 2950.2, "tracks": 41, "events": 812, "elapsed_s": 2210.5},
  "warnings": [{"code": "NO_COURT_HOMOGRAPHY", "message": "...", "severity": "warning"}]
}
```

Error response (expected failures are returned, not raised):

```json
{
  "status": "error",
  "job_id": "j_abc123",
  "error": {"code": "GPU_OOM", "message": "Out of GPU memory at batch size 1", "detail": "traceback..."},
  "warnings": []
}
```

Error codes are the strings in `modal_app/pipeline/errors.py` (= `scout.errors.ErrorCode`):
`GPU_OOM`, `VIDEO_INVALID`, `VIDEO_DECODE_FAILED`, `VIDEO_TOO_LONG`,
`VIDEO_DOWNLOAD_FAILED`, `DETECTION_FAILED`, `BALL_NOT_DETECTED`, `MODEL_LOAD_FAILED`,
`PIPELINE_FAILED`.

### Progress

While running, the pipeline writes progress into the Modal Dict
`basketball-scout-progress` (local processor: an in-memory dict) under the job id:

```json
{"stage": "detect", "pct": 42.5, "message": "Detecting players (12000/36000 frames)", "updated_at": 1730000000.0}
```

`pct` is overall progress 0–100 across all stages (`modal_app/pipeline/progress.py`).

## tracking.json.gz

Gzipped JSON validating as `scout.schemas.TrackingResult`:

| Field | Meaning |
|---|---|
| `schema_version` | `"1.0"` |
| `video` | fps, size, frame_count, duration_s, analysis_fps, codec |
| `pipeline` | name (`openhoopvision` / `builtin` / `synthetic`), version, models used, gpu, elapsed_s, options |
| `court` | `length_ft`, `width_ft`, `homographies[]` (frame ranges + 3×3 pixel→feet matrix, source `model`/`manual`/`classical`) |
| `teams[]` | team_id, dominant jersey colour (RGB + name), track_count |
| `tracks[]` | track_id, team_id, role (`player`/`referee`/`unknown`), jersey_reads[] (frame, raw text, conf), samples[] (f, bbox, court_xy, conf) |
| `ball[]` | f, xy (px), court_xy (ground projection, approximate), conf, holder_track_id, interpolated |
| `rims[]` | optional rim pixel positions (`left`/`right` in the image) |
| `events[]` | raw game events (below) |
| `warnings[]` | code/message/severity, e.g. `NO_COURT_HOMOGRAPHY`, `BALL_TRACKING_SPARSE`, `GPU_OOM_RECOVERED`, `OCR_SPARSE` |
| `artifacts` | logical name → volume path (`annotated_video`) |

### Raw events

Every event: `event_id`, `type`, `frame`, `t`, `track_id` (primary actor),
`team_id`, `conf` (0–1), `attrs`.

**Steals, blocks and assists are attributes, never separate events** — this keeps the
box score from double counting.

| type | primary `track_id` | `attrs` |
|---|---|---|
| `shot` | shooter | `made` (bool/null), `is_three` (bool/null), `shot_xy_px` [x,y], `shot_court_xy` [x,y] or null, `assisted_by_track`, `blocked_by_track`, `putback` (bool) |
| `free_throw` | shooter | `made` (bool) |
| `rebound` | rebounder | `offensive` (bool/null — null lets the server infer from the last miss) |
| `pass` | passer | `to_track`, `completed` (bool, default true) |
| `turnover` | player who lost the ball | `kind` (`steal`/`bad_pass`/`travel`/`out_of_bounds`/`offensive_foul`/`other`), `stolen_by_track` |
| `foul` | fouler (if known) | `kind` (`personal`/`shooting`/`offensive`/`technical`), `fouled_track` |
| `screen` | screener | `ball_handler_track`, `on_ball` (bool) |
| `jump_ball` | — | `won_by_team` |
| `period_start` / `period_end` | — | `period` |
| `timeout` | — | (team in `team_id`) |

Server-side rules for turning these into a box score and possessions are in
`docs/ARCHITECTURE.md` → "Event semantics".
