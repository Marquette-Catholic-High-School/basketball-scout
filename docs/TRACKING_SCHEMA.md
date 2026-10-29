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
* Court or pixel mode: without a homography, the server treats sample `court_xy` as
  court coordinates only when at least 50 % of PLAYER track samples (referee tracks
  excluded) carry one, the same share as the GPU's `EventConfig.court_mode_min_share`;
  otherwise it works in pixels and uses `shot_court_xy` per shot.
* OpenHoopVision's court y grows toward the camera (its demo output shows the ball
  handler nearest the camera at the bottom of its mini-map), so the adapter mirrors it
  to our near-sideline `y = 0`. `COURT_ORIENTATION_CHECK` stays as a safety net when a
  manual calibration exists.

## Processing request / response

The worker calls the processor (Modal function `process_video`, or the local runner)
with one dict:

```json
{
  "job_id": "j_abc123",
  "video": {"type": "volume", "path": "uploads/j_abc123/source.mp4", "filename": "vs-central.mp4"},
  "output_dir": "results/j_abc123",
  "options": {
    "analysis_fps": 15,
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
the Modal function (`modal_app/app.py`) downloads it into `/data/tmp/<job_id>/` first and
deletes it afterwards (`runner.run_pipeline` itself only takes a local file). The local
processor downloads it into its run folder the same way, but on the server, so it refuses
links whose host resolves to a private, loopback, link-local, site-local, multicast or
reserved address (also after a redirect) with `VIDEO_DOWNLOAD_FAILED`. It connects to the
address it checked, so these downloads do not go through an HTTP(S) proxy set in the
environment. A file name taken from the link is shortened to 100 characters on the GPU
(an extension of up to 10 characters, such as `.mp4`, is kept). Paths are
relative to the Modal volume root (mounted at `/data` in the container) or, for the local
processor, to its run folder `<SCOUT_DATA_DIR>/local_runs/<job_id>/`.

Optional extra `options` for testing and debugging: `max_frames` (stop after N analysed
frames), `work_dir`, `keep_work_dir` (keep OpenHoopVision's raw output) and
`max_download_bytes` (size cap for a URL film).

Time limits: the GPU function stops after `SCOUT_MODAL_TIMEOUT_S` (deploy time, default
21600 s = 6 hours, at most 86400), and the worker stops waiting after
`SCOUT_MODAL_MAX_WAIT_HOURS` (default 8) counted from the job's start, then cancels the
call (`MODAL_TIMEOUT`). While Modal cannot be reached at all it keeps waiting, until 24
hours without contact (`MODAL_REMOTE_ERROR`). Raising `SCOUT_MODAL_TIMEOUT_S` above 8
hours also requires raising `SCOUT_MODAL_MAX_WAIT_HOURS`.

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
`VIDEO_DOWNLOAD_FAILED`, `DETECTION_FAILED`, `BALL_NOT_DETECTED`, `COURT_NOT_DETECTED`,
`MODEL_LOAD_FAILED`, `PIPELINE_FAILED` (also used for a malformed processing request).
An unknown code reaching the server becomes `PIPELINE_FAILED`. Every other `ErrorCode`
comes from the server itself, for example `CONFIG_INVALID` (a file under `config/`, such
as `play_rules.yaml` or `fastscout_columns.yaml`, cannot be used; the message names the
setting).

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
| `teams[]` | team_id, dominant jersey colour (`color_rgb`, null when OpenHoopVision did not report it; `color_name` `dark` / `light`), track_count |
| `tracks[]` | track_id, team_id, role (`player`/`referee`/`unknown`), jersey_reads[] (frame, raw text, conf), samples[] (f, bbox, court_xy, conf) |
| `ball[]` | f, xy (px), court_xy (ground projection, approximate), conf, holder_track_id, interpolated |
| `rims[]` | optional rim pixel positions (`left`/`right` in the image) |
| `events[]` | raw game events (below) |
| `warnings[]` | code/message/severity (`info` / `warning` / `error`); the codes are listed below |
| `artifacts` | logical name → volume path (`annotated_video`) |

### Warning codes

Warnings never fail the job; the server shows them on the Data quality tab.
OpenHoopVision prints the ReID, OCR and GPU-memory messages while its progress bar is on
screen; the runner still picks them up from those lines.

| Code | Meaning |
|---|---|
| `NO_COURT_HOMOGRAPHY` | The court could not be mapped at all: no court positions or shot zones (a manual calibration can supply them). |
| `COURT_MAPPING_SPARSE` | Court positions exist for only part of the player sightings; shot zones may be incomplete. |
| `COURT_ORIENTATION_CHECK` | (info) OpenHoopVision's court positions match the manual calibration only when mirrored side to side. |
| `BALL_TRACKING_SPARSE` | The ball was tracked in under 30 % of frames; shots, passes and possessions may be missed. |
| `BALL_HOLDERS_UNAVAILABLE` | Ball holders could not be inferred; possessions may be incomplete. |
| `OCR_SPARSE` | Few jersey numbers could be read. |
| `OCR_UNAVAILABLE` | The jersey OCR model did not load: no jersey numbers at all. |
| `REID_UNAVAILABLE` | Re-identification did not load or failed during the run (OpenHoopVision then turns it off for the rest of the film): one player may appear as several tracks. |
| `GPU_OOM_RECOVERED` | The GPU ran low on memory and the film was analysed with smaller batches. |
| `TRACKING_DATA_TRUNCATED` | (info) Unreadable frame records from OpenHoopVision were skipped. |
| `FILM_PARTIALLY_ANALYSED` | Fewer than 90 % of the film's frames (the video stream's frame count divided by the analysis step) were analysed, so stats and plays cover only the part that was read. |
| `EVENT_ENRICHMENT_FAILED` | Assists, blocks and offensive / defensive rebounds could not be filled in. |
| `EXTRA_EVENTS_FAILED` | Free throws, fouls, screens, jump balls and periods could not be detected: OpenHoopVision's free throws stay field-goal attempts, so FGA and points run high and PF runs low. |
| `FREE_THROWS_NOT_DETECTED` | No court positions, so free throws (and the shooting fouls inferred from them) could not be detected: OpenHoopVision reports each free throw as a field-goal attempt, so FGA and points run high and PF runs low. A manual calibration sent with the GPU job lets the pipeline find them; a server-side re-analysis cannot. |
| `ANNOTATED_VIDEO_MISSING` | No overlay video was produced; the film plays without overlays. |
| `ANNOTATED_VIDEO_FAILED` | The overlay video could not be encoded; stats and the timeline are unaffected. |

### Raw events

Every event: `event_id`, `type`, `frame`, `t`, `track_id` (primary actor),
`team_id`, `conf` (0–1), `attrs`.

**Steals, blocks and assists are attributes, never separate events** — this keeps the
box score from double counting.

| type | primary `track_id` | `attrs` |
|---|---|---|
| `shot` | shooter | `made` (bool/null), `is_three` (bool/null), `shot_xy_px` [x,y], `shot_court_xy` [x,y] or null, `assisted_by_track`, `blocked_by_track`, `putback` (bool) |
| `free_throw` | shooter | `made` (bool); see the note on `replaces_event_id` below |
| `rebound` | rebounder | `offensive` (bool/null — null lets the server infer from the last miss) |
| `pass` | passer | `to_track`, `completed` (bool, default true) |
| `turnover` | player who lost the ball | `kind` (`steal`/`bad_pass`/`travel`/`out_of_bounds`/`offensive_foul`/`other`), `stolen_by_track` |
| `foul` | fouler (if known) | `kind` (`personal`/`shooting`/`offensive`/`technical`), `fouled_track` |
| `screen` | screener | `ball_handler_track`, `on_ball` (bool) |
| `jump_ball` | — | `won_by_team` |
| `period_start` / `period_end` | — | `period` |
| `timeout` | — | (team in `team_id`); `inferred: true` with `team_id` null when the pipeline found it from a stoppage |

`attrs.replaces_event_id` on a `free_throw` is internal to the pipeline:
`events.detect_events` sets it when a free throw it found coincides with an existing
`shot` event; the runner drops that shot and removes the key when it merges and
renumbers the events (`e00001`, ...), so it never appears in `tracking.json.gz`. Events
from OpenHoopVision may carry a few more attrs (`source`, `end_frame`, `points_source`,
`gained_by_track`); the server ignores attrs it does not know.

### Periods and timeouts

OpenHoopVision has no notion of periods; `events.detect_events` infers them from long
stoppages (no ball holder and at most 4 players on the floor for 45 s or more). Quarter
breaks and full timeouts look alike, so it uses the structure of a game:

* The film's first live play starts period 1.
* The longest stoppage of 5 minutes or more is halftime (of several equally long ones,
  the one nearest the middle of the film's live play).
* In each half (the whole film when there is no halftime), at most one stoppage is a
  quarter break: the one nearest the middle of that half's live play, and only when it
  falls between 30 % and 70 % of it and each side has at least 7 minutes of live play.
  An 8-minute quarter has at least 8 minutes of live play.
* Every other stoppage becomes a `timeout` event (team unknown, `attrs.inferred: true`).
  Overtime is not split off; it stays in the last period.

Server-side rules for turning these into a box score and possessions are in
`docs/ARCHITECTURE.md` → "Event semantics".

## Related server-side fields

* `Game.has_video` is true when a film file is stored on this server
  (`<SCOUT_DATA_DIR>/games/<id>/source.*`). A game whose film is a link has
  `has_video=false` and `video_url` set; the worker treats either as "film present".
* `HealthStatus.max_upload_bytes` (`GET /api/health`) is `SCOUT_MAX_UPLOAD_GB` in bytes,
  so the upload page can refuse an oversized file before sending it.
