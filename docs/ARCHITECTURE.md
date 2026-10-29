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
# A track that is no roster player never shows a roster number (another track is that player, its
# votes were too split, or it has no team and both rosters have that number): no jersey, its stats
# go to the team line. Any override but ignore makes the track a player, also one the pipeline
# called a referee (no jersey unless the override names a player).
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
Processor.should_stop: Callable[[str], bool] | None    # set by the worker: True once that job must end (cancel,
                                                       # deleted game, lost lease, worker stop); submit() checks it
PollResult.unreachable: bool                           # the processor could not be reached (state stays "running")
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
* `attempts > max_attempts` → fail with `WORKER_LOST`. With either queue, a job whose
  worker died stays `running` until another worker re-claims it; a cancel meanwhile is
  handled by that worker. A worker whose lease lapsed keeps a job that its own claim
  hands back, and steps aside when another worker has taken the job over.
* **Graceful stop** (SIGTERM, e.g. `systemctl restart`): the worker stops claiming. A
  job that is waiting on the GPU is handed back at its next poll: `worker_id` cleared,
  lease expired at once, and the attempt is not counted towards `WORKER_LOST`; the next
  worker resumes polling it. An upload to the GPU in progress, the stages after the GPU
  (download, analysis, report) and REANALYZE / REPORT jobs run to the end; systemd
  allows 120 s, then kills the worker and the job is picked up again when its lease
  expires.
* Cancelling a queued job is immediate, unless it already has a GPU call
  (`external_id`, e.g. a row an older version left `queued`): that job, like a running
  one, gets `cancel_requested=1`, and the worker that claims it cancels the processor
  call and marks it `cancelled`, also when its attempts ran out (a cancel wins over
  `WORKER_LOST`). The exception is an ANALYZE whose worker died after installing its
  new results (claimed at `analyzing` or `reporting`, `tracking.json.gz` on disk) while
  it has attempts left: the claiming worker finishes the analysis from the installed
  results, without downloading them again, as the next bullet says. Cancel is also
  checked between stages and while a failed film upload waits to be retried.
* A cancel stops an ANALYZE only until its new results are installed: a results
  download in progress is thrown away, so the game keeps its earlier tracking,
  overlay, analysis and track overrides. Once the results are installed (stage
  `analyzing`), the analysis runs to the end and the job ends `succeeded`; a cancel then
  only skips the automatic report. Either way a job warning says so: "Cancelled after
  the new GPU results were in place: the analysis was finished, the scouting report was
  skipped." (without the report clause when no report was due, or when Claude was
  already writing the report: that report is kept). A GPU poll or a results download
  that fails after the coach asked to cancel ends the job `cancelled`, not `failed`;
  when another worker has taken the job over meanwhile, the worker steps aside instead.
  The job panel's Cancel confirm says so for an ANALYZE at `analyzing` or `reporting`,
  and **Start again** on a cancelled Full re-analysis of a game that has an analysis
  asks first, like the Full re-analysis button (the film goes to the GPU again and the
  track assignments are cleared).
* A film upload to the Modal volume that fails is tried twice more, after 10 s and
  30 s (not after an auth error, a film that is gone, or a cancelled upload). A cancel
  during those waits ends the job as `cancelled` within a second; a graceful stop hands
  the job back for the next worker instead of retrying.
* On a failure, a cancel or the max-wait timeout the worker also cancels a GPU call that
  may still be running and, with `SCOUT_MODAL_CLEANUP=true`, deletes the film and
  results from the Modal volume (`processor.cancel` / `processor.cleanup`).
* The wait limit `SCOUT_MODAL_MAX_WAIT_HOURS` is measured from `Job.started_at` (the
  first claim), so worker restarts do not extend it → `MODAL_TIMEOUT`. Raising
  `SCOUT_MODAL_TIMEOUT_S` (the GPU function's own limit) above 8 hours therefore also
  needs a higher `SCOUT_MODAL_MAX_WAIT_HOURS`. While Modal cannot be reached at all
  (`PollResult.unreachable`), the limit does not end the wait: a job resumed after the
  server was off would otherwise fail on its first poll, and its cleanup could delete
  results that are waiting. After 24 hours without contact (counted by the worker
  process) the job fails with `MODAL_REMOTE_ERROR`.
* Modal keeps a call's result for 7 days. When it has expired but
  `results/<job_id>/tracking.json.gz` is still on the volume, the worker downloads that
  file (and `annotated.mp4`, if there) instead of failing with `MODAL_RESULT_EXPIRED`.
* A resumed job is polled by the processor that created its handle (`Job.processor`),
  even if `SCOUT_PROCESSOR` changed in between.
* Retryable failures (see `scout/errors.py`) show a Retry button in the UI
  (`POST /api/jobs/{id}/retry` creates a new job). Retrying an ANALYZE job that failed
  after the GPU results were saved (stage `analyzing` or `reporting`, `tracking.json.gz`
  on disk) starts a REANALYZE instead, so the film is not sent to the GPU again. The
  page offers that retry, labelled **Re-run analysis**, even when the error is not
  retryable (for example `CONFIG_INVALID`): once the coach has fixed the cause, the
  cheap retry is what they need.
* Game status follows the latest ANALYZE/REANALYZE job: `queued`, `processing`,
  `ready` (analysis.json written) or `failed` (with `Game.error`). After a cancel it
  goes back to `ready`, `uploaded` or `draft`, decided from the files on disk. The worker
  settles the game status before it marks the job finished (success, failure and
  cancel alike), so a page that reloads the game when its job ends sees the final status.
* When an ANALYZE installs its outputs, the worker sets `has_annotated_video` at once,
  so a failure later in the job does not leave the flag pointing at a removed file. New
  tracking installed over an earlier run's also clears the game's track overrides (see
  **Full re-analysis** below).
* An ANALYZE downloads its results into the game folder's `.incoming/` and moves them
  into place in one step, so a download cut short (the worker killed mid-download, a
  full disk) leaves the earlier run's tracking, overlay and track overrides together.
  A worker whose job was taken over during the download steps aside: it neither
  installs nor fails it. When an ANALYZE ends without installing (failed or
  cancelled), its worker removes `.incoming/`.
* A report failure after a successful analysis does NOT fail the ANALYZE job; it is
  recorded as a job warning and the coach can click "Generate report" again.
* Mock processor (`SCOUT_PROCESSOR=mock`): the seed of the synthetic game is written to
  `TrackingResult.pipeline.options["seed"]`; the worker uses it to save matching demo
  rosters when the game has none.

## HTTP API

All routes require HTTP Basic auth except `GET` / `HEAD /api/health/live`. Errors are JSON
`{"error": ErrorInfo}` with the status from `scout.errors` (validation errors: 422 +
`VALIDATION_FAILED`, detail lists the bad fields).

Sign-in errors come from the auth middleware (`scout/auth.py`), before any route runs,
so their codes are plain strings, not `ErrorCode` members: `AUTH_REQUIRED` (401 with a
`WWW-Authenticate` challenge), `AUTH_THROTTLED` (429 with `Retry-After`; 10 wrong
passwords from one address within 5 minutes lock it out for 5 minutes, 30 from one
IPv6 /64 network lock out the network) and `AUTH_NOT_CONFIGURED` (503: no password or
hash set, or the hash is malformed). Failures expire after 5 minutes, and a successful
sign-in does not clear an address's count. A browser that signs in successfully gets an
HttpOnly `scout_device` cookie (`SameSite=Lax`, `Secure` over HTTPS, HMAC-signed with a
key kept in memory, so a restart or a password change issues new ones). While it holds
one, address and network lockouts do not apply to it, but it has its own limit of 10
failures in 5 minutes; it is not a credential, as every request still needs the
password. `CROSS_SITE_REQUEST` (403) comes from the
same-origin middleware in front of it: a POST/PUT/PATCH/DELETE that the browser marks
as sent by another website (`Sec-Fetch-Site`, else `Origin` / `Referer` against `Host`
or `X-Forwarded-Host`) is refused, even with auth disabled. `HOST_NOT_ALLOWED` (403)
comes from the same middleware: the request's `Host`, or a name in `X-Forwarded-Host`
(where a proxy that rewrites `Host` puts the browser's; it can only refuse a request,
never allow one), is not one the server answers to (`SCOUT_ALLOWED_HOSTS`, `*.school.org`
for subdomains, `*` for any name; IP addresses, `localhost` and `*.localhost` always
work; when it is empty, any name while auth is on, and with auth disabled only those and
the machine's own name, which blocks DNS rebinding). `GET` / `HEAD /api/health/live` is exempt.
Request bodies are capped (`REQUEST_TOO_LARGE`, 413): 1 MB for JSON, 4 MB for a
multipart form such as a roster file; upload chunks have their own limit (twice the
upload's chunk size, `UPLOAD_TOO_LARGE`). The interactive API docs are at `/api/docs` and
`/api/openapi.json` (behind sign-in).

Extra rules beyond the table:

* **409 `CONFLICT` while an analysis job (ANALYZE / REANALYZE) is queued or running:** it
  blocks starting or completing an upload, setting a video URL and every new job,
  REPORT included. Only one REPORT job per game may be active at a time. While an
  ANALYZE is queued or running it also blocks `PUT` / `DELETE
  /api/games/{id}/tracks/{track_id}`: its new run numbers the tracks again, and
  installing it clears the overrides (see **Full re-analysis**), so a fix made
  meanwhile would be dropped without a word.
* **New film** (a completed upload or a video URL) deletes the old film, tracking,
  annotated video and `analysis.json` (`has_analysis` becomes false) and clears the
  track overrides, the coach's team-colour choice (`team_id_map`) and the court
  calibration: track and team ids from the old film mean nothing for the new one, and
  the calibration was clicked on the old film's frame. It also aborts the game's other
  open uploads and deletes their `.part` files, and what a results download cut short
  left in the game's `.incoming/` folder. A video URL game has `has_video=false`,
  `video_url` set (the GPU downloads it; the local processor downloads it on the server
  and refuses links whose host resolves to a private, loopback, link-local, site-local,
  multicast or reserved address, also after a redirect). Video links must be `http(s)`
  with a valid host and port (0-65535); a file name taken from the link is URL-decoded,
  has control characters turned into spaces and is cut to 255 characters, keeping an
  extension of up to 10 characters (the upload page sends only the link).
* **Full re-analysis** (an ANALYZE of a game that already has GPU results) sends the
  film and the court calibration to the GPU again; the old results stay until the new
  ones are installed. When the worker installs the new tracking over the earlier
  run's, it clears the track overrides (the new run may number its tracks
  differently) and deletes the earlier run's `analysis.json` (`has_analysis` becomes
  false until the new analysis is saved, about a minute later), so no page shows the
  earlier run's track ids over the new tracking, also when that analysis fails (a
  Roster page opened before the Full re-analysis started reads the tracks again before
  it saves, and shows the new table instead of saving when they were numbered again);
  `team_id_map` stays, because OpenHoopVision's team ids are its dark/light jersey
  clusters.
* **Uploads**: starting an upload aborts the game's open uploads that have had no data
  for an hour. `PUT /api/uploads/{id}/chunk` answers 409 `UPLOAD_INCOMPLETE` with the
  current upload after 120 s without data, so the browser can resume from `received`.
  The browser itself aborts a chunk whose upload has made no progress for 60 s and
  resumes from `received` (`GET /api/uploads/{id}`).
* `POST /api/games/{id}/jobs` checks `params.coach_focus` like `ReportRequest` for
  every kind (kind=report keeps only `coach_focus`): ANALYZE and REANALYZE jobs that
  write the report send it to Claude too.
* `GET /api/games/{id}/video` is sent with `Cache-Control: no-cache`: the URL stays the
  same when the film is replaced or re-analysed, so browsers revalidate with the ETag.
* `PUT /api/games/{id}/tracks/{track_id}`: `track_id` in the body is optional; the one
  in the path wins.
* `GET /api/games/{id}/jobs` lists the newest job first.
* Cancelling a queued ANALYZE / REANALYZE job puts the game back to `ready`, `uploaded`
  or `draft` at once (one that already has a GPU call: once the worker has stopped that
  call).

Pages: `GET /` (games), `GET /upload` (new game + film; `?game=<id>` to add film to an
existing game), `GET /games/{id}` (results), `GET /games/{id}/roster`. Assets under
`/static/`.

| Method & path | Body | Returns |
|---|---|---|
| `GET /api/health` | | `HealthStatus` |
| `GET` / `HEAD /api/health/live` (no auth) | | `{"status": "ok"}` (HEAD: headers only) |
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
* **Event side** = the side of the actor's track (manual override, then the track's
  team, then the roster assignment); the event's own `team_id` only when the actor's
  team is unknown, and for team events. OpenHoopVision's per-event team label can
  flicker, while the track's majority team is stable. An assist or block credited to a
  player of the other team is dropped.
* **Rebounds**: `rebound` → OREB when the rebounder's side matches the side of the last
  missed FG/FT (both known); when either side is unknown, the pipeline's `offensive`
  flag decides; else DREB.
* **Turnovers / steals**: `turnover` → TOV+1 for the player who lost it; with
  `kind="steal"` or `stolen_by_track`, a STEAL row and STL+1 for the stealer. A steal
  credited to a teammate of the player who lost the ball (the pipeline's team label
  flickered) is dropped: with `kind="steal"` the STEAL row goes to the other team's
  line, otherwise there is no STEAL row.
* **Fouls**: `foul` → PF+1 for the fouler.
* **Possessions** change on: a made FG (unless the scoring team's free throw is the next
  ball event: an and-one), the made last FT of a trip (technical-foul free throws: the
  shooting team keeps the ball), a defensive rebound, a turnover, a jump ball and a
  period start. Offensive rebounds continue the possession.
  * After a made basket the possession flips at once, unless the scoring team's free
    throw is the next ball event (an and-one: the other team has not done anything with
    the ball yet); then the flip is undone and the free throw belongs to the scoring
    possession. This holds however long the film takes to get to the line, and however
    long the shooter holds the ball for the official.
  * **Dead balls.** After a shooting foul the ball is dead until the fouled team's free
    throws, and between two free throws of one trip: a `rebound` then is dropped, and a
    hold by the other team does not change possession. A hold by the team that has just
    scored (a field goal or its last free throw), before the other team acts, does not
    start a possession either.
  * A missed last free throw does not flip the possession by itself: the rebound decides.
  * Gaps are filled from ball-holder segments of 2 s or more, and a shot, free throw,
    turnover or offensive rebound by the team without the ball also starts an `inferred`
    possession. When the other team gains control (a ball-holder segment of 2 s or more,
    a shot or a turnover) within 4 s of a shot or last free throw known to have missed
    (`made: false`, or blocked; a `made: null` shot may have gone in) that nobody was
    credited with rebounding, and nothing stopped play (a whistle, free throws, a period
    break, or the shooting team holding the ball for 2 s), the new possession counts as
    an unseen defensive rebound (reason `def_rebound`, a live start) but no DREB is
    credited. It starts when that control starts, often the outlet receiver's hold, so
    it can begin about a second after the real rebound.
  * **Transition** (`Possession.transition`, FastScout's fast-break points): a live
    start (defensive rebound, steal, live-ball turnover), the possession's last field-goal
    attempt, turnover or fouled shot within 10 s of the start, and no timeout or common
    foul before it. OpenHoopVision reports a turnover only for a direct change of control
    within 0.5 s, so a turnover without a known dead-ball kind (`travel`,
    `out_of_bounds`, `offensive_foul`) counts as live.
  * `points_per_possession` = points / possessions for that side.
* Unknown player → stat goes to the team's `team_unattributed` line.
* `GameAnalysis.data_quality.warnings` holds the pipeline's warnings
  (docs/TRACKING_SCHEMA.md) plus the server's own: `NO_ROSTER`, `COURT_NOT_MAPPED`
  (pixel mode: no homography and no calibration) and `LOW_JERSEY_MATCH` (under 50 % of
  player time matched to a roster jersey). The server also adds
  `FREE_THROWS_NOT_DETECTED` when the pipeline reported `NO_COURT_HOMOGRAPHY`, found no
  free throws and did not send that warning itself. When the server applied the coach's
  calibration, the pipeline's `NO_COURT_HOMOGRAPHY` / `COURT_MAPPING_SPARSE` warnings are
  dropped (the calibration answers them), but `FREE_THROWS_NOT_DETECTED` stays: free
  throws are found on the GPU, so only a full re-analysis (ANALYZE, which sends the
  calibration to the GPU) detects them.
* **Calibration and re-analysis.** A REANALYZE after the coach re-calibrates or removes
  the calibration replaces a calibration that the GPU run had baked in (its `manual`
  homography and the positions projected with it); positions from the pipeline's court
  model are kept.

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
