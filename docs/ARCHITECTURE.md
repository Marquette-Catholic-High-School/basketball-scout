# Architecture

```
 Browser (vanilla HTML/JS)                         Modal (serverless A10G GPU)
 ┌───────────────────────────┐                     ┌──────────────────────────────┐
 │ /            games list   │                     │ modal_app/app.py             │
 │ /upload      drag & drop  │                     │  process_video(request)      │
 │ /games/{id}  results      │                     │   └ pipeline.runner          │
 │ /games/{id}/roster        │                     │      video → detect → track  │
 └────────────┬──────────────┘                     │      → pose → OCR → teams    │
              │ HTTP Basic auth                     │      → court → ball holders │
 ┌────────────▼──────────────┐  submit / poll      │      → events → render       │
 │ FastAPI  (scout.main)     │◄───────────────┐    │  Volume: basketball-scout-data│
 │  /api/...  JSON API       │                │    │  Dict:   ...-progress        │
 │  static pages             │                │    └──────────────▲───────────────┘
 └────────────┬──────────────┘                │                   │ Modal SDK
              │ SQLite (jobs, games, rosters) │                   │ (upload, spawn,
 ┌────────────▼──────────────┐                │                   │  poll, download)
 │ Worker (scout.worker)     │────────────────┘───────────────────┘
 │  queue: SQLite or Redis   │
 │  ANALYZE: upload → GPU → download → transform → (Claude report)
 │  REANALYZE: transform only (after roster / track edits)
 │  REPORT: Claude report only
 └───────────────────────────┘
```

## Repository layout

| Path | What |
|---|---|
| `scout/schemas.py` | All data contracts (tracking, analysis, domain/API). |
| `scout/config.py` | Settings (`SCOUT_*` env vars, `.env`). |
| `scout/errors.py` | Error codes + coach-facing messages (`ScoutError`). |
| `scout/db.py` | SQLite persistence (games, jobs, rosters, overrides, reports, uploads). |
| `scout/storage.py` | Per-game files under `data/games/<id>/`. |
| `scout/main.py`, `scout/auth.py`, `scout/api/` | FastAPI app, basic auth, routers. |
| `scout/static/` | Frontend pages, JS, CSS (no framework, no build step). |
| `scout/jobs/` | Queue backends (`queue.py` SQLite, `redis_queue.py`). |
| `scout/worker.py` | Job runner. |
| `scout/processing/` | Processor interface + Modal / local / mock processors. |
| `scout/analysis/` | Transform: geometry, tracking index, teams, events/possessions, plays, box score, pipeline, synthetic generator. |
| `scout/roster/` | Roster import and jersey matching. |
| `scout/export/` | FastScout paste block / CSV, timeline CSV. |
| `scout/reporting/` | Claude report (payload, prompts, rendering). |
| `modal_app/` | Modal app + GPU computer-vision pipeline. |
| `config/` | `court.yaml`, `play_rules.yaml`, `fastscout_columns.yaml`. |
| `scripts/` | `install.sh`, `uninstall.sh`, `update.sh` (servers), `dev.sh` (local development). |
| `deploy/` | systemd units, nginx site. |
| `tests/` | pytest suite (`tests/helpers.py` builds small TrackingResults). |

## Module interfaces

The signatures below are fixed; see each module's docstrings for details.

```python
# scout.analysis.pipeline
load_tracking(path) -> TrackingResult
analyze_game(tracking, game, rosters, overrides=None, *, court=None, rules=None) -> GameAnalysis
save_analysis(analysis, path) / load_analysis(path) -> GameAnalysis

# scout.analysis.teams
resolve_team_map(tracking, game) -> dict[int, TeamSide]
side_of(team_map, team_id) -> TeamSide | None

# scout.analysis.events
player_ref(track_id, assignments, rosters) -> PlayerRef | None   # assignments: {track_id: TrackAssignment}
build_timeline(tracking, index, team_map, assignments, rosters, court) -> TimelineBuild

# scout.analysis.boxscore
build_box_scores(timeline, possessions, assignments, rosters, team_names, index=None) -> list[TeamBoxScore]

# scout.analysis.plays
load_play_rules(path=None) -> PlayRules
detect_plays(index, timeline, possessions, assignments, team_map, court, rules) -> list[Play]
link_plays(timeline, possessions, plays) -> None
summarize_plays(plays, possessions) -> list[PlayTypeSummary]

# scout.analysis.synthetic
generate_synthetic_game(*, seed=7, duration_s=600, fps=30, analysis_fps=10, with_homography=True, ocr_noise=0.15, filename=...) -> (TrackingResult, SyntheticTruth)
synthetic_rosters(game_id, *, seed=7) -> dict[TeamSide, Roster]

# scout.analysis.geometry / tracking_index  (implemented; shared helpers)

# scout.roster.importer
parse_roster_file(filename, content: bytes) -> RosterParseResult
merge_players(existing: Roster, incoming, mode="replace"|"merge") -> Roster
# Both modes: an incoming player whose jersey is already on the roster keeps that player's
# id ("replace" still replaces all of his data), so manual track assignments survive a re-import.

# scout.roster.matcher
normalize_jersey(text) -> str | None
jersey_similarity(read, jersey) -> (score, method)
jersey_votes(reads, *, min_conf=0.2) -> dict[str, float]
match_votes(votes, roster, *, accept=0.5) -> (RosterPlayer | None, score, method)
assign_tracks(tracking, team_map, rosters, overrides=None) -> list[TrackAssignment]
match_name(query, roster, *, threshold=80) -> (RosterPlayer | None, score)

# scout.export.fastscout   (roster= defaults to the game's current roster in the database)
load_fastscout_config(path=None) -> dict                     # a broken file: CONFIG_INVALID naming the key
validate_fastscout_config(data, *, source="config") -> dict
build_paste_block(analysis, game, side=SCOUTED, config=None, *, roster=None) -> str
paste_block_warnings(analysis, game, side=SCOUTED, config=None, *, roster=None) -> list[str]
team_helper_block(analysis, side=SCOUTED) -> str             # team numbers FastScout wants typed in
list_custom_tables(config=None) -> list[str]
custom_table_titles(config=None) -> dict[str, str]
build_custom_table_csv(analysis, game, side=SCOUTED, table=None, config=None, *, roster=None) -> str
build_timeline_csv(analysis, config=None) -> str
sanitize_fastscout_name(text) -> str                         # letters and spaces only
jersey_words(jersey) -> str                                  # "23" -> "Twenty Three" (unrostered players)

# scout.reporting.claude_report
build_report_payload(analysis, game, rosters, *, token_budget=PAYLOAD_TOKEN_BUDGET) -> dict
generate_report(analysis, game, rosters, *, coach_focus=None, settings=None, client=None) -> ReportRecord
# scout.reporting.render
report_to_markdown(report: ScoutingReport, game: Game, *, model: str | None = None) -> str

# scout.jobs.queue
get_queue(settings=None) -> JobQueue        # .enqueue(job_id) .claim(worker_id, timeout) .ack(...) .requeue_stale() .ping()
                                            # .heartbeat(worker_id): optional hook (no-op; the Redis queue tracks live workers)
submit_job(game_id, kind, params=None, *, queue=None) -> Job   # if enqueue fails, the new row is marked failed, then the error is raised

# scout.processing   (Processor, PollResult and poll_result_from_response live in scout/processing/base.py)
get_processor(settings=None, name=None) -> Processor   # submit / poll / fetch / cancel / cleanup / check_ready
Processor.poll_interval: float | None                  # seconds between polls; None = SCOUT_MODAL_POLL_SECONDS
poll_result_from_response(response) -> PollResult      # pipeline response dict -> PollResult (Modal and local processors)

# scout.worker
Worker(settings=None, queue=None, processor=None, worker_id=None).run_forever() / run_once(timeout) / process_job(job)

# modal_app.pipeline
runner.run_pipeline(video_path, options, *, output_dir, job_id, progress=None, filename=None) -> response dict
    # video_path is a local file; modal_app/app.py downloads a {"type": "url"} film first
possession.assign_ball_holders(perception, cfg=None) -> None
events.enrich_events(perception, existing_events, cfg=None) -> list[dict]   # copies with assists, blocks, rebound types filled in
events.detect_events(perception, cfg=None, existing_events=None) -> list[dict]
    # only NEW events (free throws, fouls, screens, jump balls, periods), deduplicated against existing_events
result.build_tracking_result(perception, events, *, job_id, pipeline_info, artifacts=None, sample_stride=1) -> dict
```

## Job lifecycle

`Job.status`: `queued → running → succeeded | failed | cancelled`.
`Job.stage` (ANALYZE): `queued → preparing → uploading_to_gpu → gpu_processing →
downloading_results → analyzing → reporting → done`. `progress` is 0–100 overall.

* The API creates the job row (`db.create_job`) and calls `queue.enqueue`.
* A worker claims it (lease = `SCOUT_JOB_LEASE_SECONDS`, renewed by heartbeat while
  running). If a worker dies, the lease expires and another worker re-claims the job;
  because `Job.external_id` (the Modal FunctionCall id) was saved right after submit,
  the new worker resumes polling instead of resubmitting.
* `attempts > max_attempts` → fail with `WORKER_LOST`.
* **Graceful stop** (SIGTERM, e.g. `systemctl restart`): the worker stops claiming. A
  job that is waiting on the GPU is handed back at its next poll: `worker_id` cleared,
  lease expired at once, and the attempt is not counted towards `WORKER_LOST`; the next
  worker resumes polling it. An upload to the GPU in progress, the stages after the GPU
  (download, analysis, report) and REANALYZE / REPORT jobs run to the end; systemd
  allows 120 s, then kills the worker and the job is picked up again when its lease
  expires.
* Cancelling a queued job is immediate; a running job gets `cancel_requested=1` and
  the worker cancels the processor call and marks it `cancelled`. Cancel is also
  checked between stages.
* On a failure, a cancel or the max-wait timeout the worker also cancels a GPU call that
  may still be running and, with `SCOUT_MODAL_CLEANUP=true`, deletes the film and
  results from the Modal volume (`processor.cancel` / `processor.cleanup`).
* The wait limit `SCOUT_MODAL_MAX_WAIT_HOURS` is measured from `Job.started_at` (the
  first claim), so worker restarts do not extend it → `MODAL_TIMEOUT`. Raising
  `SCOUT_MODAL_TIMEOUT_S` (the GPU function's own limit) above 8 hours therefore also
  needs a higher `SCOUT_MODAL_MAX_WAIT_HOURS`.
* A resumed job is polled by the processor that created its handle (`Job.processor`),
  even if `SCOUT_PROCESSOR` changed in between.
* Retryable failures (see `scout/errors.py`) show a Retry button in the UI
  (`POST /api/jobs/{id}/retry` creates a new job).
* Game status follows the latest ANALYZE/REANALYZE job: `queued`, `processing`,
  `ready` (analysis.json written) or `failed` (with `Game.error`). After a cancel it
  goes back to `ready`, `uploaded` or `draft`, decided from the files on disk.
* A report failure after a successful analysis does NOT fail the ANALYZE job; it is
  recorded as a job warning and the coach can click "Generate report" again.
* Mock processor (`SCOUT_PROCESSOR=mock`): the seed of the synthetic game is written to
  `TrackingResult.pipeline.options["seed"]`; the worker uses it to save matching demo
  rosters when the game has none.

## HTTP API

All routes require HTTP Basic auth except `GET /api/health/live`. Errors are JSON
`{"error": ErrorInfo}` with the status from `scout.errors` (validation errors: 422 +
`VALIDATION_FAILED`, detail lists the bad fields).

Sign-in errors come from the auth middleware (`scout/auth.py`), before any route runs,
so their codes are plain strings, not `ErrorCode` members: `AUTH_REQUIRED` (401 with a
`WWW-Authenticate` challenge), `AUTH_THROTTLED` (429 with `Retry-After`; 10 wrong
passwords from one address within 5 minutes lock it out for 5 minutes, 30 from one
IPv6 /64 network lock out the network) and `AUTH_NOT_CONFIGURED` (503: no password or
hash set, or the hash is malformed). `CROSS_SITE_REQUEST` (403) comes from the
same-origin middleware in front of it: a POST/PUT/PATCH/DELETE that the browser marks
as sent by another website (`Sec-Fetch-Site`, else `Origin` / `Referer` against `Host`
or `X-Forwarded-Host`) is refused. The interactive API docs are at `/api/docs` and
`/api/openapi.json` (behind sign-in).

Extra rules beyond the table:

* **409 `CONFLICT` while an analysis job (ANALYZE / REANALYZE) is queued or running:** it
  blocks starting or completing an upload, setting a video URL and every new job,
  REPORT included. Only one REPORT job per game may be active at a time.
* **New film** (a completed upload or a video URL) deletes the old film, tracking,
  annotated video and `analysis.json` (`has_analysis` becomes false) and clears the
  track overrides and the coach's team-colour choice (`team_id_map`): track and team
  ids from the old film mean nothing for the new one. A video URL game has
  `has_video=false`, `video_url` set (the GPU downloads it).
* `PUT /api/games/{id}/tracks/{track_id}`: `track_id` in the body is optional; the one
  in the path wins.
* `GET /api/games/{id}/jobs` lists the newest job first.
* Cancelling a queued ANALYZE / REANALYZE job puts the game back to `ready`, `uploaded`
  or `draft` at once.

Pages: `GET /` (games), `GET /upload` (new game + film; `?game=<id>` to add film to an
existing game), `GET /games/{id}` (results), `GET /games/{id}/roster`. Assets under
`/static/`.

| Method & path | Body | Returns |
|---|---|---|
| `GET /api/health` | | `HealthStatus` |
| `GET /api/health/live` (no auth) | | `{"status": "ok"}` |
| `GET /api/court/landmarks` | | `{"court": {...CourtConfig}, "landmarks": {name: [x, y]}}` |
| `GET /api/games` | | `list[Game]` (newest first) |
| `POST /api/games` | `GameCreate` | `Game` (201) |
| `GET /api/games/{id}` | | `Game` |
| `PATCH /api/games/{id}` | `GameUpdate` | `Game` |
| `DELETE /api/games/{id}` | | 204 (cancels jobs, deletes files) |
| `POST /api/games/{id}/uploads` | `UploadInit` | `UploadSession` (201) |
| `GET /api/uploads/{upload_id}` | | `UploadSession` (resume: `received`) |
| `PUT /api/uploads/{upload_id}/chunk?offset=N` | raw bytes | `UploadSession`; 409 + current session if `offset != received` |
| `POST /api/uploads/{upload_id}/complete?auto_start=true` | | `{"game": Game, "job": Job \| null}` |
| `DELETE /api/uploads/{upload_id}` | | 204 |
| `POST /api/games/{id}/video-url?auto_start=true` | `VideoUrlRequest` | `{"game": Game, "job": Job \| null}` |
| `POST /api/games/{id}/jobs` | `JobCreate` | `Job` (201); 409 if an analysis job is already active |
| `GET /api/games/{id}/jobs` | | `list[Job]` (newest first) |
| `GET /api/jobs/{job_id}` | | `Job` |
| `POST /api/jobs/{job_id}/cancel` | | `Job` |
| `POST /api/jobs/{job_id}/retry` | | `Job` (new) |
| `GET /api/games/{id}/analysis` | | `GameAnalysis`; 409 `ANALYSIS_NOT_READY` |
| `GET /api/games/{id}/video?variant=original\|annotated` | | MP4 with HTTP Range support |
| `PUT /api/games/{id}/calibration` | `{"points": [CalibrationPoint], "frame_t", "video_width", "video_height"}` | `CourtCalibration` |
| `DELETE /api/games/{id}/calibration` | | 204 |
| `GET /api/games/{id}/rosters` | | `{"scouted": Roster, "other": Roster}` |
| `GET /api/games/{id}/rosters/{side}` | | `Roster` |
| `PUT /api/games/{id}/rosters/{side}` | `{"team_name"?, "players": [RosterPlayer]}` | `Roster` |
| `POST /api/games/{id}/rosters/{side}/import` | multipart `file`, `mode=replace\|merge` | `RosterImportResult` |
| `POST /api/games/{id}/rosters/{side}/players` | `RosterPlayer` (id optional) | `Roster` |
| `PATCH /api/games/{id}/rosters/{side}/players/{player_id}` | partial `RosterPlayer` | `Roster` |
| `DELETE /api/games/{id}/rosters/{side}/players/{player_id}` | | `Roster` |
| `GET /api/roster-template.csv` | | CSV template |
| `GET /api/games/{id}/tracks` | | `{"assignments": [TrackAssignment], "overrides": [TrackOverride]}` |
| `PUT /api/games/{id}/tracks/{track_id}` | `TrackOverride` (`track_id` optional) | `TrackOverride` |
| `DELETE /api/games/{id}/tracks/{track_id}` | | 204 |
| `GET /api/games/{id}/export/fastscout.txt?side=scouted` | | `text/plain` paste block |
| `GET /api/games/{id}/export/fastscout-notes?side=scouted` | | `{"warnings": [str], "team_numbers": str}`: what to check before pasting, and the team numbers typed in by hand |
| `GET /api/games/{id}/export/fastscout.csv?side=scouted&table=` | | `text/csv` |
| `GET /api/export/fastscout/tables` | | `list[str]` custom table names |
| `GET /api/games/{id}/export/timeline.csv` | | `text/csv` |
| `GET /api/games/{id}/export/analysis.json` | | JSON download |
| `GET /api/games/{id}/export/report.md?report_id=` | | `text/markdown` (latest by default) |
| `GET /api/games/{id}/reports` | | `list[ReportRecord]` |
| `POST /api/games/{id}/reports` | `ReportRequest` | `Job` (202, kind=report) |
| `GET /api/reports/{report_id}` | | `ReportRecord` |

Export/download routes accept `?download=1` to add `Content-Disposition: attachment`.

## Event semantics (box score rules)

* **Field goals**: each `shot` event → one SHOT_MADE/SHOT_MISSED row for the shooter:
  FGA+1 (FGM+1, PTS+2/3 when made). 3PA/3PM when the shot is a three (court geometry
  when a location is known, else the pipeline's `is_three`). Zone split: paint / mid /
  three / unknown.
* **Assist**: `assisted_by_track` on a MADE shot → ASSIST row, AST+1 for the passer.
* **Block**: `blocked_by_track` → BLOCK row, BLK+1 for the blocker (the shot counts as a
  miss).
* **Free throws**: `free_throw` → FT_MADE/FT_MISSED, FTA+1 (FTM+1, PTS+1).
* **Rebounds**: `rebound` → OREB when `offensive` is true (or, when null, the rebounder's
  side matches the side of the last missed FG/FT), else DREB.
* **Turnovers / steals**: `turnover` → TOV+1 for the player who lost it; with
  `kind="steal"` or `stolen_by_track`, a STEAL row and STL+1 for the stealer.
* **Fouls**: `foul` → PF+1 for the fouler.
* **Possessions** change on: a made FG, a made last FT of a trip, a defensive rebound,
  a turnover, a jump ball and a period start. Offensive rebounds continue the
  possession.
  * After a made basket the possession flips at once, unless the scoring team's free
    throw is the next ball event (an and-one: the other team has not done anything with
    the ball yet); then the flip is undone and the free throw belongs to the scoring
    possession. This holds however long the film takes to get to the line.
  * A missed last free throw does not flip the possession by itself: the rebound decides.
  * Gaps are filled from ball-holder segments, and a shot, free throw, turnover or
    offensive rebound by the team without the ball also starts an `inferred` possession.
  * `points_per_possession` = points / possessions for that side.
* Unknown player → stat goes to the team's `team_unattributed` line.
* `GameAnalysis.data_quality.warnings` holds the pipeline's warnings
  (docs/TRACKING_SCHEMA.md) plus the server's own: `NO_ROSTER`, `COURT_NOT_MAPPED`
  (pixel mode: no homography and no calibration) and `LOW_JERSEY_MATCH` (under 50 % of
  player time matched to a roster jersey).

## Configuration

Everything is set in `.env` (see `.env.example`); the important groups:

* Server: `SCOUT_HOST`, `SCOUT_PORT`, `SCOUT_DATA_DIR`.
* Auth: `SCOUT_AUTH_USERNAME`, `SCOUT_AUTH_PASSWORD` or `SCOUT_AUTH_PASSWORD_HASH`.
* Queue: `SCOUT_QUEUE_BACKEND=sqlite|redis`, `SCOUT_REDIS_URL`, `SCOUT_WORKER_CONCURRENCY`.
* Processing: `SCOUT_PROCESSOR=modal|mock|local`, `SCOUT_MODAL_*`, `SCOUT_ANALYSIS_FPS`,
  `SCOUT_RENDER_ANNOTATED_VIDEO`, `MODAL_TOKEN_ID`, `MODAL_TOKEN_SECRET`.
* Claude: `ANTHROPIC_API_KEY`, `SCOUT_CLAUDE_MODEL` (default `claude-opus-5-5`),
  `SCOUT_CLAUDE_EFFORT`, `SCOUT_CLAUDE_MAX_TOKENS`, `SCOUT_AUTO_REPORT`.
* Files: `config/court.yaml`, `config/play_rules.yaml`, `config/fastscout_columns.yaml`.
