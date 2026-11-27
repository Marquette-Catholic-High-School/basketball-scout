# Live games

A live game is analysed while it is played. A **capture client** (the Mac app) reads the
camera's stream, cuts it into parts of about two minutes and uploads each part; the server sends
every part to the GPU as it arrives and rebuilds the stats, so the box score, shot chart and
plays fill in during the game. When the stream ends, the parts are joined into the film and the
game becomes a normal game.

```
  Camera / encoder                 Coach's Mac (any network)             Scout server
  rtmp://192.168.1.50/live  --->   Mac app: ffmpeg cuts the stream  ---> POST /live/segments + chunks
  (the gym's network)              into parts, uploads each (https)       |
                                                                          v
                                   game page: stats so far   <---   LIVE job: GPU per part,
                                   (any device)                     join, analysis.json
```

The server never sees the stream link and never connects to the camera: the Mac only needs
ordinary https to the server (a domain name, a tunnel or a VPN), so it works from another
school's network.

## Contents

- [What to expect](#what-to-expect)
- [Data](#data)
- [HTTP API](#http-api)
- [The LIVE job](#the-live-job)
- [How the parts are joined](#how-the-parts-are-joined)
- [What a capture client does](#what-a-capture-client-does)
- [Settings](#settings)

## What to expect

- **The stats trail the game.** A part is sent when it is complete (2 minutes by default) and
  then needs the GPU. The GPU is expected to be slower than real time, so several parts run at
  once (`SCOUT_LIVE_MAX_PARALLEL`, and `SCOUT_MODAL_MAX_CONTAINERS` at deploy time, both 3 or
  more). Expect the stats about **5 to 10 minutes** behind the game. This has **not been
  measured**: like the rest of the GPU pipeline, live games have only run against test data
  ([README, "What is not verified yet"](../README.md#what-is-not-verified-yet)).
- **The stats are always "through" a time.** The analysis covers the stream from its start up to
  the first part still on the GPU, never with a hole for a part that is still to come.
- **Breaks are breaks.** In a part filmed during halftime, a timeout or warm-ups the GPU finds
  no play (too few players in view, or no ball). Such a part is settled as *empty*: no stats, no
  error, and the long stretch without play is how halftime is recognised.
- **A part the GPU cannot analyse leaves a gap**, not a failed game: the Data quality tab says
  which stretch of film has no stats.
- **Cuts cost a little.** Each part is analysed on its own. A play that straddles the cut between
  two parts (a shot released in one and landing in the next) can be missed, and every part tracks
  the players anew, so a player is named in a part only when his jersey number is read in that
  part. After the game, **Full re-analysis** runs the whole film in one piece: no cuts, and the
  overlay video, which live parts skip to save GPU time.
- **Cost.** About the same GPU time as analysing the film afterwards, spent during the game, plus
  a container start per GPU used.

## Data

`Game.live` is `null` for a normal game. For a live game:

```json
{
  "state": "capturing",
  "segment_seconds": 120,
  "segments_received": 7,
  "segments_analysed": 5,
  "segments_failed": 0,
  "segments_empty": 0,
  "received_s": 842.1,
  "analysed_s": 601.3,
  "analysis_version": 5,
  "started_at": "2026-12-04T00:31:10Z",
  "last_segment_at": "2026-12-04T00:45:22Z",
  "ended_at": null,
  "end_reason": null
}
```

| Field | Meaning |
|---|---|
| `state` | `capturing` (takes film), `finishing` (no more film; the parts on the GPU are finished), `ended` |
| `segment_seconds` | length of the parts the client sends |
| `segments_received`, `received_s` | parts on the server, and their film time |
| `segments_analysed`, `analysed_s` | parts whose stats are in the analysis; the analysis covers the film up to `analysed_s` |
| `segments_failed` | parts the GPU could not analyse |
| `segments_empty` | parts without play (a break, warm-ups): settled, no stats, not failures |
| `analysis_version` | goes up by one each time `analysis.json` is rebuilt: reload the analysis when it changes |
| `end_reason` | `finished` (ended by the coach), `idle` (no film for `SCOUT_LIVE_IDLE_MINUTES`), `limit` (`SCOUT_MAX_VIDEO_MINUTES` reached), `cancelled`, `failed`, `empty` (ended before any film arrived) |

`Game.status` is `queued`, then `processing` until the first part is analysed, then `ready`
**while the game is still live**: a client shows the results as soon as `has_analysis` is true and
keeps refreshing until `live.state` is `ended`. `has_video` and `has_tracking` become true when
the game ends (the film is joined, `tracking.json.gz` is written).

One part (`live_segments` table, `LiveSegment`):

```json
{"game_id": "g_ab12", "index": 7, "duration_s": 120.1, "size": 48211234, "filename": "part-00007.mp4",
 "status": "processing", "attempts": 1, "progress": 40.0, "error": null,
 "uploaded_at": "...", "submitted_at": "...", "finished_at": null}
```

`status`: `uploaded` (waiting for a GPU), `processing`, `done`, `failed` (with `error`), `empty`
(no play was found in it; `error` says what the GPU answered).

Files, until the game ends: `<SCOUT_DATA_DIR>/games/<id>/live/seg-00007.mp4` and
`seg-00007.tracking.json.gz`. At the end they become `source.mp4` and `tracking.json.gz`, and
`live/` is removed.

## HTTP API

All under `/api`, with the same sign-in as the rest.

| Method and path | Purpose |
|---|---|
| `POST /api/games/{game_id}/live` | Make the game a live game and queue its LIVE job. Body (optional): `{"segment_seconds": 120}` (20 to 600; default `SCOUT_LIVE_SEGMENT_SECONDS`). `201` → `LiveStatus`. Asked again while it is capturing: `200` with the running session. `409 CONFLICT` when the game already has film or another analysis is running; `409 LIVE_ENDED` when its live stream has ended. |
| `GET /api/games/{game_id}/live` | `LiveStatus`: `{"game": Game, "segments": [LiveSegment], "job": Job}`. `404` for a game that was never live. |
| `POST /api/games/{game_id}/live/segments` | An upload session for one part. Body: `{"index": 7, "duration_s": 120.1, "size": 48211234, "filename": "part-00007.mp4"}` (MP4 only). `201` → `UploadSession` with `live_segment: 7`. `200` when the part is already here (`status: "complete"`: send nothing) or half-sent with the same size (`status: "open"`: resume from `received`). `409 LIVE_ENDED` once the game no longer takes film. |
| `POST /api/games/{game_id}/live/finish` | No more film is coming. `200` → `LiveStatus` with `state: "finishing"`. Can be repeated. |

The part's bytes go through the normal upload routes: `PUT /api/uploads/{upload_id}/chunk?offset=N`
and `POST /api/uploads/{upload_id}/complete` (→ `{"game": Game, "job": Job}`), exactly as for a
whole film ([ARCHITECTURE.md, "HTTP API"](ARCHITECTURE.md#http-api)). `complete` on a live part
adds it to the stream instead of replacing the film.

`POST /api/jobs/{job_id}/cancel` on the LIVE job stops the live analysis at once: the GPU calls
are cancelled, the stats so far are kept and the film that arrived is joined.
`POST /api/jobs/{job_id}/retry` on a LIVE job that failed or was cancelled starts a normal
analysis of the joined film, or, when the film was not joined, a new LIVE job that finishes the
parts still on the server.

While a game is live no other analysis job starts, and its film cannot be replaced. Uploading a
film or setting a video link after it has ended makes it a normal game again (`live: null`).

## The LIVE job

One job (`kind: "live"`) per live game, in `scout/live_runner.py`. It holds one worker slot for
the length of the game and keeps up to `SCOUT_LIVE_MAX_PARALLEL` GPU calls going. Every
`SCOUT_MODAL_POLL_SECONDS` it:

1. polls the GPU calls of the parts that are `processing`, and stores the results of those that
   finished (`done`). A part the GPU rejects with `DETECTION_FAILED` or `BALL_NOT_DETECTED` (film
   without a game in it) becomes `empty`. A call that failed with a retryable error is sent once
   more; otherwise the part is `failed` and the job gets the warning "Part 3 of the film could not
   be analysed: ...". A part still on the GPU after `SCOUT_LIVE_SEGMENT_TIMEOUT_MINUTES` is
   cancelled and `failed`.
2. sends `uploaded` parts to the GPU, oldest first. Each call runs under the id
   `<job id>-p<index>` (`j_ab12-p00007`), without the overlay video.
3. rebuilds the analysis when the settled front of the stream grew, or when a roster, a track
   assignment, the team colours or the court calibration changed (so a roster fix shows in the
   stats within one round, without a job of its own).
4. ends the game once `state` is `finishing` and every part is settled. `state` becomes
   `finishing` when the client says so, when no film arrived for `SCOUT_LIVE_IDLE_MINUTES`, or
   when the game reached `SCOUT_MAX_VIDEO_MINUTES`.

At the end the joined tracking is saved as `tracking.json.gz`, the parts are joined into
`source.mp4` with ffmpeg (no re-encoding; without ffmpeg on the server the parts stay in `live/`
and the job says so), the scouting report is written when `SCOUT_AUTO_REPORT` is on, and the job
ends `succeeded` with the message "Live game analysed".

`Job.stage` stays `gpu_processing` during the game (then `reporting`); `Job.message` reads
"Live: 5 of 7 parts analysed, stats through 10:00".

- **Worker restart.** Each part's GPU call is saved on its row, so the next worker resumes the
  calls instead of paying for them again, and rebuilds the join from the parts' results on disk.
- **Cancel** stops the job at any time before the report (`cancel_stops_job`).
- **Failure.** Taking the film comes first. A part that fails is a gap; a rebuild of the stats
  that fails mid-game is a job warning ("The stats could not be rebuilt (...); the film is still
  being recorded.") and is tried again with the next part. The job itself fails only at the start
  (no GPU credentials: the coach should know before tip-off) or at the end (the last rebuild
  failed, or no part at all could be analysed), when the film and `tracking.json.gz` are already
  in place for **Re-run analysis** or a normal analysis.
- **No film at all.** A game ended before any part arrived goes back to `draft`
  (`end_reason: "empty"`) and can go live again.

## How the parts are joined

`scout/analysis/live_merge.py` puts the parts' `TrackingResult`s on one timeline:

- **Frames** move by the length of the parts before. A part without results still takes its
  time, so the timeline stays in step with the film.
- **Track ids** become `part index * 100000 + track id`. The id depends only on the part, so it
  never changes as more parts arrive and a track assignment made during the game stays valid.
- **Teams** are matched to the first analysed part's teams by jersey colour (name, else RGB).
- **Events** keep their order; their ids get the part as a prefix (`p0007-e00012`).
- **Periods.** A 2-minute part cannot see a halftime, so the parts' own `period_start`,
  `period_end` and inferred `timeout` events are dropped and the GPU pipeline's period detector
  (`modal_app.pipeline.events.detect_period_events`, pure Python and numpy) runs on the joined
  tracking. An `empty` part is a stoppage like any other there; a `failed` part is a hole in the
  data and is never read as a timeout.
- **Warnings**: one per code, plus `LIVE_PARTS_MISSING` naming the stretches that failed and
  `LIVE_NO_PLAY` (info) naming the stretches without play.

`pipeline.options.live` is `true` in a joined tracking.

## What a capture client does

The Mac app does this ([apple/README.md](../apple/README.md#live-games)); any client can.

1. `POST /live` once, with the part length it will use.
2. Cut the stream into MP4 parts **without re-encoding the video**, each starting on a key frame
   and playable on its own, numbered from 0 in stream order. With ffmpeg:

   ```bash
   ffmpeg -nostdin -i "$STREAM" -map 0:v:0 -map 0:a:0? -c:v copy -c:a aac -b:a 96k \
     -f segment -segment_time 120 -segment_format mp4 -reset_timestamps 1 \
     -segment_list parts.csv -segment_list_type csv part-%05d.mp4
   ```

   A line in `parts.csv` (`part-00007.mp4,840.0,960.1`) means that part is complete.
3. Send the parts **in order**, one at a time: `POST /live/segments`, the chunks, `complete`.
   Keep a part on disk until `complete` answered. On a network error, try again; the session
   resumes. A part the client has lost is simply left out: the server skips an index that has
   not arrived two minutes after a later one did.
4. If the stream drops, reconnect and carry on with the next index.
5. `POST /live/finish` after the last part is sent.
6. On `409 LIVE_ENDED`, stop: the game no longer takes film (ended from another device, idle,
   the length limit, or its job was cancelled or failed).

## Settings

| Setting | Default | Meaning |
|---|---|---|
| `SCOUT_LIVE_SEGMENT_SECONDS` | `120` | Length of each part when the client does not say (20 to 600). Shorter parts bring the stats sooner and cut more plays in two. |
| `SCOUT_LIVE_MAX_PARALLEL` | `3` | GPU calls at once for one live game. Keep `SCOUT_MODAL_MAX_CONTAINERS` and `SCOUT_MODAL_MAX_GPUS` at least as high (they are set when the Modal app is deployed). A 2-minute part is one piece on one GPU. |
| `SCOUT_LIVE_IDLE_MINUTES` | `45` | A live game ends by itself after this long without new film. |
| `SCOUT_LIVE_SEGMENT_TIMEOUT_MINUTES` | `30` | Longest wait for the GPU on one part before it is given up. |

`SCOUT_MAX_VIDEO_MINUTES` also limits a live game's total length, and `SCOUT_MAX_UPLOAD_GB` one
part's size.
