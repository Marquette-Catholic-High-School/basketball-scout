# Basketball Scout

Self-hosted opponent scouting for high school basketball. A coach uploads an
opponent's game film; computer vision on a rented GPU follows the players and the
ball; the server turns that into an event timeline, a box score, shot zones, play
types and defensive looks; Claude writes a scouting report; and the numbers export
straight into FastScout.

Built for Marquette Catholic High School. It runs on one small Ubuntu server (or a
Proxmox VM) on the school network. The GPU work is rented by the minute from
[Modal](https://modal.com), so the server needs no graphics card.

> **The statistics come from computer vision and are approximate.** Check anything you
> build a game plan on against the film. See [Accuracy](#accuracy-what-to-trust).

Repository: <https://github.com/Marquette-Catholic-High-School/basketball-scout.git>

## Contents

- [What it does](#what-it-does)
- [How it works](#how-it-works)
- [What is not verified yet](#what-is-not-verified-yet)
- [Try it in 5 minutes (demo, no GPU)](#try-it-in-5-minutes-demo-no-gpu)
- [Setup](#setup)
  - [What you need](#what-you-need)
  - [Proxmox VM](#proxmox-vm)
  - [Install on an Ubuntu server](#install-on-an-ubuntu-server)
  - [Modal (the GPU)](#modal-the-gpu)
  - [Anthropic API key (the report)](#anthropic-api-key-the-report)
  - [Redis (optional)](#redis-optional)
  - [Run it on your own computer](#run-it-on-your-own-computer)
  - [Update](#update)
  - [Uninstall](#uninstall)
- [Using the app](#using-the-app)
- [Configuration reference](#configuration-reference)
- [Config files](#config-files)
- [Costs](#costs)
- [Troubleshooting](#troubleshooting)
- [Accuracy: what to trust](#accuracy-what-to-trust)
- [Security and privacy](#security-and-privacy)
- [Project layout](#project-layout)
- [Running the tests](#running-the-tests)
- [Credits](#credits)

More documentation:
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) (design and API),
[docs/TRACKING_SCHEMA.md](docs/TRACKING_SCHEMA.md) (GPU pipeline output),
[docs/FASTSCOUT.md](docs/FASTSCOUT.md) (FastScout step by step),
[docs/PROXMOX.md](docs/PROXMOX.md) (the VM),
[docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) (production checklist, backups, monitoring).

## What it does

- **Drag-and-drop upload** of MP4 game film (MOV and M4V too). Uploads go in chunks and
  resume after a dropped connection. A direct link to an MP4 works as well.
- **Background job queue**, so a 60-minute game never blocks the site. Close the
  browser and come back; the game page shows each stage and its progress. Jobs survive
  a server restart, and a GPU job is never paid for twice.
- **Results timeline**: every event in order (shots, free throws, rebounds, assists,
  steals, blocks, turnovers, fouls, screens) with the video time, event type, player
  and jersey, team, a **possession indicator**, the running score and a confidence.
  Filter it, search it, click a time to watch the moment.
- **Annotated playback**: the film with player boxes, jersey numbers and the ball
  drawn in, next to the original, with next/previous-event buttons and keyboard
  shortcuts.
- **Rosters per game** for both teams: import CSV or Excel (MaxPreps, Hudl and
  FastScout exports, team sheets, even a plain "number, name" list) or type them in.
  Jersey numbers read from the film are matched to names with **fuzzy matching for OCR
  mistakes** (8 read as 3, 1 as 7...). You can fix any track by hand.
- **Box score** per player: points, FG, 3PT, FT, offensive and defensive rebounds,
  assists, steals, blocks, turnovers, fouls and approximate minutes, plus team totals
  and points per possession.
- **Shot zones**: paint, mid-range and three, with a shot chart, using the court
  mapping (homography) when the court lines were found.
- **Play recognition** (rule-based, on top of the tracking data): pick and roll, pick
  and pop, isolation, fast break, post-up, handoff, off-ball screen, spot-up, cut and
  putback, with possessions, points per possession and outcomes. Defense: man, zone
  (with shapes such as 2-3 or 1-3-1) and full-court press.
- **Claude scouting report**: the structured stats and plays go to Claude with a
  high school coach's brief; the report comes back in fixed sections (summary,
  offensive and defensive identity, key players, play tendencies, transition, keys to
  win, game plans, practice emphasis, data caveats) that you can print or download as
  Markdown. Add your own focus ("how do they handle ball screens?").
- **FastScout exports**: a paste block for the FastScout Classic **Stats Database**
  and CSV files for **FastScout Web Custom Table** tiles (box score, shot zones, play
  types, defensive looks), plus a timeline CSV for Excel. Columns are configurable.
- **Basic auth** on every page (one coaches' login), with a lockout after repeated
  wrong passwords.
- **Clear errors**: GPU out of memory, players or ball not detected, Modal not set up,
  report failures and more each come with a plain-English explanation, a hint, and a
  Retry button when retrying can help. See [Troubleshooting](#troubleshooting).

## How it works

```
  Coach's browser (Chrome, Edge, Safari)
        |   HTTPS (nginx + certbot, or Tailscale) and the coaches' login
        v
  +-------------------------------+
  | Web app          scout.main   |  pages + JSON API: upload, results,
  | (FastAPI, plain HTML + JS)    |  rosters, exports, report
  +---------------+---------------+
                  |  SQLite database: games, jobs, rosters, reports
                  |  job queue: SQLite (default) or Redis
  +---------------v---------------+  film (Modal SDK)   +-----------------------------------+
  | Worker         scout.worker   | ------------------> | Modal: process_video (A10G GPU)   |
  |  transform: possessions,      |                     |  modal_app/app.py runs            |
  |  box score, shot zones,       | <------------------ |  OpenHoopVision: detection,       |
  |  play recognition, FastScout  |  tracking.json.gz   |  tracking, pose, jersey OCR,      |
  +---------------+---------------+  + annotated.mp4    |  court mapping, events, overlay   |
                  |                                     +-----------------------------------+
                  |  stats + plays as JSON (never video)
                  v
          Claude API (scouting report)
```

The web app and the worker are two processes (two systemd services on a server). The
worker uploads the film to a Modal Volume, starts the GPU function, polls its progress,
downloads the results and runs the transform; re-running the transform after a roster
fix takes about a minute and no GPU. Details, job states and the HTTP API:
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). What the GPU returns:
[docs/TRACKING_SCHEMA.md](docs/TRACKING_SCHEMA.md).

## What is not verified yet

This is a new system. Every part has automated tests (with stand-ins for the GPU, Modal
and Claude), and the whole app was clicked through in a browser with the demo processor.
What has not been tried yet:

- **No run on a real GPU or on real game film.** The Modal app and the OpenHoopVision
  pipeline have only run against test data, so the time and cost per game and the
  accuracy on high school film are estimates. Before the first real game, run
  `make warmup-modal` (or `modal run modal_app/app.py::warmup`) and analyse one short clip.
- **The FastScout formats come from archived FastScout documentation** and screenshots,
  not from a live FastScout account. Paste one game into a spare schedule entry first
  ([docs/FASTSCOUT.md](docs/FASTSCOUT.md#caveats-and-what-is-unverified)).
- **The install, update and uninstall scripts** were run with stand-ins for apt, systemd
  and nginx, not yet on a real Ubuntu 24.04 server. Take a VM snapshot before the first
  install.
- **Left and right on the court** as OpenHoopVision reports them were checked on its own
  demo output only, not on real film. Paint, mid-range, three and 2-vs-3 calls do not
  depend on it, and with a manual calibration the `COURT_ORIENTATION_CHECK` note flags a
  mirror.
- **Thresholds are tuned on synthetic games.** Play recognition (`config/play_rules.yaml`)
  and the period detector were tuned on generated tracking data. Pick-and-roll,
  pick-and-pop and handoff detection need the screener to stand nearly still; if real
  tracking jitters by more than about half a foot, raise
  `pick_and_roll.screener_max_speed_fts`, `handoff.giver_max_speed_fts` or
  `general.speed_window_s` after the first real film.

## Try it in 5 minutes (demo, no GPU)

The **mock processor** (`SCOUT_PROCESSOR=mock`) skips the GPU and turns any upload into
a realistic synthetic game, so you can click through everything without a Modal
account. You need Python 3.11 or newer (macOS: `brew install python@3.12`).

```bash
git clone https://github.com/Marquette-Catholic-High-School/basketball-scout.git
cd basketball-scout
scripts/dev.sh          # or: make dev
```

`scripts/dev.sh` creates `.venv`, installs the requirements, writes a development
`.env` (`SCOUT_PROCESSOR=mock`, password `dev`) and runs the web app and the worker
together. Ctrl-C stops both.

1. Open <http://127.0.0.1:8000> and sign in as **coach** / **dev**.
2. Click **New game**, type two team names and continue.
3. Drop in any short MP4 or MOV (a phone video works; the demo ignores what is in it).
4. About 10 seconds later the game is ready: try the timeline, the video, the box
   score, the plays and the exports.
5. Optional: put `ANTHROPIC_API_KEY=sk-ant-...` in `.env`, restart `scripts/dev.sh`
   and click **Generate report**.

## Setup

### What you need

| What | Notes |
|---|---|
| A server or VM | Ubuntu Server 24.04 LTS (Debian 12 also works). Recommended: 8 vCPUs, 32 GB RAM, 200 GB disk. No GPU needed. [docs/PROXMOX.md](docs/PROXMOX.md) has a ready-made Proxmox VM. |
| Internet access | Outbound HTTPS to github.com, pypi.org and files.pythonhosted.org (Python packages), modal.com and api.anthropic.com. |
| A Modal account | <https://modal.com>. The Starter plan includes $30 of credit each month. |
| An Anthropic API key | <https://console.anthropic.com>, only for the written report. |
| Game film | MP4 from Hudl or a camera; a wide angle that shows the whole court, 720p or better. |

### Proxmox VM

On a Proxmox VE host, [docs/PROXMOX.md](docs/PROXMOX.md) has the complete `qm create`
command and the reasons behind each setting. In short: machine type `q35`, OVMF (UEFI)
firmware with an EFI disk, CPU type `host` (1 socket, 8 cores), 32 GB RAM with
ballooning off, a 200 GB disk on VirtIO SCSI single (`iothread=1,discard=on,ssd=1`), a
VirtIO network card, the QEMU guest agent, and Ubuntu Server 24.04 LTS inside. With
Modal (the default) the VM needs no GPU.

### Install on an Ubuntu server

On the server, as a user with sudo:

```bash
sudo apt-get update && sudo apt-get install -y git
git clone https://github.com/Marquette-Catholic-High-School/basketball-scout.git
cd basketball-scout
sudo scripts/install.sh --with-nginx
```

The installer asks for the Modal token and the Anthropic key (press Enter to skip
either), then works for a few minutes. At the end it prints the web address, the
username (`coach`) and a **generated password, shown only once**. Write it down.

Common variations:

| Goal | Command |
|---|---|
| Plain install, app on port 8000, no nginx | `sudo scripts/install.sh` |
| nginx on port 80 with a host name (ready for HTTPS) | `sudo scripts/install.sh --with-nginx --domain scout.myschool.org` |
| Redis job queue | `sudo scripts/install.sh --with-redis` |
| No questions (automation); keys from the environment | `sudo MODAL_TOKEN_ID=ak-... MODAL_TOKEN_SECRET=as-... ANTHROPIC_API_KEY=sk-ant-... scripts/install.sh -y --deploy-modal` |
| Demo server without a GPU account | `sudo scripts/install.sh --processor mock -y` |
| Use this machine's NVIDIA GPU instead of Modal | `sudo scripts/install.sh --processor local` (see [docs/PROXMOX.md](docs/PROXMOX.md)) |
| Without cloning first | `curl -fsSL https://raw.githubusercontent.com/Marquette-Catholic-High-School/basketball-scout/main/scripts/install.sh \| sudo bash -s -- --with-nginx` |

All options: `scripts/install.sh --help` (`--dir`, `--data-dir`, `--user`, `--branch`,
`--repo`, `--port`, `--with-redis`, `--with-nginx`, `--domain`, `--processor`,
`--modal-token-id`, `--modal-token-secret`, `--anthropic-key`, `--deploy-modal`, `-y`).

What the installer does: checks the OS, disk space and internet access; installs
`git`, Python, `ffmpeg`, `sqlite3` (and `nginx` / `redis-server` when asked); creates
the system user `scout`; clones the code; builds the Python environment; writes
`.env` with a generated password; installs and starts the two systemd services; sets
up nginx; waits until the app answers; and prints a summary with next steps.

Where things live:

| What | Where |
|---|---|
| Code and Python environment | `/opt/basketball-scout` (the venv is `.venv` inside) |
| Settings, passwords and keys | `/opt/basketball-scout/.env` (mode 600: root and `scout` only) |
| Games, film, database | `/var/lib/basketball-scout` |
| Services | `basketball-scout-web`, `basketball-scout-worker` |
| Service user | `scout` (no login shell, home `/home/scout`) |
| nginx site | `/etc/nginx/sites-available/basketball-scout` |
| Logs | `journalctl -u basketball-scout-web -u basketball-scout-worker -f` |

Running the installer again is safe: it updates the code, keeps your `.env` (it only
adds settings that are new and the values you pass as options, after saving a copy),
keeps your data and password, and restarts the services. Use it to add
`--with-nginx` or `--with-redis` later. Private repository? See
[docs/DEPLOYMENT.md](docs/DEPLOYMENT.md#private-github-repository).

The services in brief: the web unit runs `uvicorn scout.main:app` and the worker unit
runs `python -m scout.worker` (flags: `--once`, `--concurrency N`, `--worker-id NAME`,
`--log-level LEVEL`), both as `scout`, sandboxed so they can write only to the data
folder and the service user's home. Templates: `deploy/systemd/`, `deploy/nginx/`.

### Modal (the GPU)

The film is analysed by `process_video` in `modal_app/app.py`: an A10G GPU (24 GB)
running [OpenHoopVision](https://github.com/feifeifei85/OpenHoopVision) (RF-DETR
player and ball detection, RTMPose skeletons, court keypoints, tracking with
re-identification, jersey-number OCR), then possession, events and the annotated
video. The app also owns a Volume `basketball-scout-data` (film and results in transit)
and a Dict `basketball-scout-progress` (progress).

1. **Account.** Sign up at <https://modal.com>. The Starter plan includes $30 of
   credit per month.
2. **Token.** In the Modal dashboard open Settings > API Tokens > New Token and copy
   the token ID (`ak-...`) and secret (`as-...`). Give them to `install.sh` when it
   asks, or put them in `.env`:

   ```bash
   MODAL_TOKEN_ID=ak-...
   MODAL_TOKEN_SECRET=as-...
   ```

   Alternatives: `modal token new` (opens a browser sign-in and writes
   `~/.modal.toml`; on the server run it as the service user with
   `sudo -u scout -H /opt/basketball-scout/.venv/bin/modal token new`), or
   `modal token set --token-id ak-... --token-secret as-...`. Values in `.env` win
   over `~/.modal.toml`. Restart the worker after adding a token.
3. **Deploy** the GPU app. On the server:

   ```bash
   sudo /opt/basketball-scout/scripts/update.sh --deploy-modal
   ```

   On a development machine: `make deploy-modal`, or `modal deploy modal_app/app.py`.
   The first deploy builds the image once (roughly 10-20 minutes): Debian, PyTorch for
   CUDA 13, OpenHoopVision at a pinned commit and its model weights, all baked in.
   Later deploys reuse it and take a minute or two.
4. **Verify** (optional; starts one GPU container for a few minutes):
   `make warmup-modal`, or `modal run modal_app/app.py::warmup`. It loads every model
   on a real GPU, runs a two-second test clip and prints a JSON report ending in
   `"ok": true`.
5. **Test a film from the command line** (optional, no web app involved):
   `modal run modal_app/app.py --video game.mp4` uploads the file, shows progress and
   saves `tracking.json.gz` and `annotated.mp4` in `./modal_output/`.
6. **Logs:** `modal app logs basketball-scout` (add `-f` to follow).

On the server, Modal commands that need the token from `.env` run like this:

```bash
cd /opt/basketball-scout
sudo -u scout -H .venv/bin/python -m dotenv -f .env run -- .venv/bin/modal run modal_app/app.py::warmup
```

Deploy-time options (read by `modal_app/app.py` during `modal deploy`, so redeploy
after changing them): `SCOUT_MODAL_GPU` (default `A10G`), `SCOUT_MODAL_TIMEOUT_S`
(default 21600 = 6 hours per film) and `SCOUT_MODAL_MAX_CONTAINERS` (default 2 GPUs at
once). Put them in `.env`, so `update.sh` keeps using them on later deploys. If you
raise `SCOUT_MODAL_TIMEOUT_S` above 8 hours, also raise `SCOUT_MODAL_MAX_WAIT_HOURS`
(default 8): the worker stops waiting after that many hours, counted from the start of
the job, and cancels the GPU call (while Modal cannot be reached at all it keeps
waiting, until 24 hours without contact: `MODAL_REMOTE_ERROR`). To stop the GPU app:
`modal app stop basketball-scout -y` (redeploy to bring it back); to delete the Volume
and what is on it: `modal volume delete basketball-scout-data -y`.

### Anthropic API key (the report)

1. Create a key at <https://console.anthropic.com> (Settings > API Keys) and set a
   monthly spend limit there.
2. Put it in `/opt/basketball-scout/.env` (or give it to `install.sh`):
   `ANTHROPIC_API_KEY=sk-ant-...`
3. Restart the worker: `sudo systemctl restart basketball-scout-worker`.

The report uses `claude-opus-5-5` (`SCOUT_CLAUDE_MODEL`) at effort `high`
(`SCOUT_CLAUDE_EFFORT`), asks for structured JSON output and caches the game data
between requests (prompt caching). Without a key everything else works; the report
tab explains what is missing.

### Redis (optional)

The default queue is the SQLite database itself: nothing to install, and right for one
server. Redis gives instant job pickup and lets several worker processes share one
queue. Job state stays in SQLite either way; Redis only hands out job ids.

```bash
sudo scripts/install.sh --with-redis
```

That installs `redis-server`, sets `SCOUT_QUEUE_BACKEND=redis` and
`SCOUT_REDIS_URL=redis://localhost:6379/0` in `.env`, and starts both services after
Redis. By hand: `sudo apt install redis-server`, set those two values, restart both
services. Back to SQLite: set `SCOUT_QUEUE_BACKEND=sqlite` and restart.

### Run it on your own computer

For development on macOS or Linux (Python 3.11+). The quick way is
`scripts/dev.sh` / `make dev` (see the [demo](#try-it-in-5-minutes-demo-no-gpu)). By hand:

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements-dev.txt
cp .env.example .env            # then edit: SCOUT_PROCESSOR=mock and SCOUT_AUTH_PASSWORD=dev
```

Then run the two processes in two terminals:

```bash
.venv/bin/python -m uvicorn scout.main:app --reload --host 127.0.0.1 --port 8000
.venv/bin/python -m scout.worker
```

`pip install -e .` also gives you the `scout-web` and `scout-worker` commands. To use
the real GPU from your computer, run `.venv/bin/modal token new`, set
`SCOUT_PROCESSOR=modal`, and `make deploy-modal`.

| Make target | What it does |
|---|---|
| `make install` | create `.venv`, install `requirements-dev.txt` |
| `make dev` | web app (auto-reload) + worker; Ctrl-C stops both |
| `make test` | run the test suite |
| `make run-web` / `make run-worker` | only one of the two processes |
| `make deploy-modal` / `make warmup-modal` | deploy / check the GPU app (loads `.env`) |
| `make lint` | ruff (if installed) and a syntax check of the shell scripts |
| `make clean` | delete caches (never `.env`, `data/` or `.venv`) |

### Update

```bash
sudo /opt/basketball-scout/scripts/update.sh
```

It refuses to run over local code changes, such as edited `config/*.yaml` files
(`--force` saves them in `git stash` and a `.patch` file, updates, and puts them back
on top; if the new version changed the same lines, it keeps the new version, says so
and leaves your changes in the stash and the patch). It remembers the current
version, pulls from GitHub (`git fetch` + fast-forward, as the `scout` user), installs
the Python requirements (with `SCOUT_PROCESSOR=local` also `modal_app/requirements-gpu.txt`
and the OpenHoopVision commit pinned in `modal_app/pipeline/ohv.py`, when they changed),
runs the database migrations, redeploys the GPU app when
`modal_app/` changed (and Modal credentials exist; force it with `--deploy-modal`, skip
it with `--no-deploy-modal`), restarts both services, checks that the app answers and
lists the new commits. At the end, and when a step fails, it prints the commands that go
back to the previous version (`git reset --hard <old commit>`, reinstall requirements
(for a local GPU also the GPU packages and the old OpenHoopVision commit),
redeploy the GPU app if this update redeployed it, restart). After a failure you can
also fix the problem and run `update.sh` again: it remembers which version the services
and Modal really run, so it finishes the restart and redeploy even though the code is
already pulled. Other options: `--branch NAME`, `--skip-restart`, `--dir DIR`.

On Proxmox, take a snapshot first ([docs/PROXMOX.md](docs/PROXMOX.md#snapshots-before-updates)).
GPU jobs that are running on Modal continue during the restart; the worker picks them
up again.

### Uninstall

```bash
sudo /opt/basketball-scout/scripts/uninstall.sh
```

Removes the services, the nginx site and `/opt/basketball-scout` (code and Python
environment). With `SCOUT_PROCESSOR=local` it also deletes the OpenHoopVision checkout
(`OHV_HOME`, default `/opt/openhoopvision`) and
`/etc/modules-load.d/basketball-scout-nvidia.conf`; the NVIDIA driver stays installed.
The data folder stays, with a copy of `.env` in
`/var/lib/basketball-scout/backups/`, so `install.sh` restores everything later.
Options: `--purge` (also delete all games and film; asks you to type DELETE),
`--remove-user` (delete the `scout` user and its home), `--remove-modal` (stop the GPU
app on Modal and offer to delete its Volume), `--yes`, `--dir`, `--data-dir`. nginx,
Redis and the other system packages stay installed.

## Using the app

### 1. Create a game and upload the film

**Games > New game**: the team you are scouting, their opponent in this film, date,
location, level, and the colour the scouted team wears in this film (dark, light or a
specific colour). The colour helps the analysis tell the teams apart.

Then drag the film onto the page (or choose the file). Uploads can be paused and resume
after a dropped connection. You can also paste a **direct link to an MP4 file** that
the GPU can download (a Hudl or YouTube page link will not work). Processing starts
automatically; a full game takes a while (an estimated 1-3 GPU hours for 60 minutes of
film, not yet measured), and you can close the browser meanwhile.

Getting good film:

- **Hudl**: open the full game and use Hudl's download option to save it as an MP4
  (menus vary by Hudl version and your permissions). Download the whole game, not
  a highlight playlist.
- **Angle**: the standard wide "game" angle from high on the sideline that shows the
  whole court. Close-ups, end-line cameras and highlight reels fail with
  `DETECTION_FAILED`.
- **Quality**: 720p or better (1080p is ideal), H.264 MP4. The ball is small; low
  resolution or heavy compression leads to `BALL_NOT_DETECTED`.
- **Length**: up to `SCOUT_MAX_VIDEO_MINUTES` (150) and `SCOUT_MAX_UPLOAD_GB` (12 GB).

### 2. Rosters and jersey matching

Each game has two rosters (the scouted team and their opponent) on the **Roster**
page. Import a CSV or Excel (`.xlsx`) file: MaxPreps copies, Hudl or FastScout
exports and team sheets all work; title rows, extra columns and header-less
"number, name" lists are handled. **Download roster template** gives a ready-made CSV
(`Jersey, First Name, Last Name, Position, Grade, Height, FastScout Name, Notes`).
Choose *replace* or *merge*, or type players in. "0" and "00" are different numbers.

Jersey numbers read from the film are matched to the roster, tolerating typical OCR
mistakes (8/3/0, 1/7, 5/6, missing digits). The **Jersey assignments from the film**
table lists every tracked player with the readings and the match; pick the right
player when it is wrong, choose a team's **Unknown player** when you know the team but
not the player (also for a track the tracker took for a referee), or mark referees and
spectators as **Not a player**, then **Save & re-run analysis** (about a minute, no
GPU). **Unknown player (keep team)** keeps the team the table shows. **Unclear match**
means the best read is a roster number, but another track was matched to that player,
the readings were too split to be sure, or both rosters have that number and the track
has no team: assign it yourself if you know who it is. If the film was analysed again
(a **Full re-analysis**, for example from another tab) since you opened the page,
**Save & re-run analysis** shows the new table instead of saving: make your choices
again there. The FastScout name column sets the exact spelling FastScout expects.

### 3. Confirm the team colours

The analysis splits players into two teams by jersey colour. If it is not sure which
is the scouted team, the game page asks **"Which team is ...?"**: click the right
jersey colour and the stats are recomputed.

### 4. Court calibration (fixed cameras only)

Shot zones and court positions need the court mapped. OpenHoopVision usually finds
the court lines by itself; the **Data quality** tab says whether it did. If not, and
the camera **never moved** (tripod, no pan or zoom): **Calibrate court**, find a frame
with clear floor lines, pick a landmark, click exactly where it is, add at least 4
points spread across the court, **Save calibration**, then **Re-run analysis**
(**Analyze film** for a game that has not been analysed yet). For a panning camera
there is nothing to calibrate; zones stay approximate. Set the gym's length in
`config/court.yaml` if you know it.

Free throws are found on the GPU and need court positions. If the first run could not
map the court, the Data quality tab warns that free throws were not detected
(`FREE_THROWS_NOT_DETECTED`): after you calibrate, choose **Full re-analysis** (in that
warning or at the top of the game page; it sends the film to the GPU again, with your
calibration) instead of **Re-run analysis**, which only redoes the stats on this server.
A Full re-analysis numbers the players' tracks again, so it clears the track
assignments you made on the Roster page; the Roster page locks them while it runs and
takes new ones once it has finished (choices you had not saved are dropped once its
new tracks are in place). Cancelling it before its new results are in place keeps the
earlier results. A new film clears the calibration, since it was clicked on the old film.

### 5. Reading the results

- **Video**: switch between *Annotated* and *Original*, change the speed, step to the
  previous or next event. Keys: Space play/pause, Left/Right 5 seconds (Shift: 1
  second), `[` and `]` previous/next event.
- **Event timeline**: time, event, player, shot zone, team, **possession** (which team
  has the ball and the possession number), running score and confidence. Filter by
  team, event type, player or play type, search, or turn on *Follow video*. Click a
  time to jump there.
- **Box score**: per player, with a *Team* line for stats the film could not tie to a
  player. MIN is approximate on-floor video time (stoppages included).
- **Shot chart**: made and missed shots by zone (paint, mid-range, three).
- **Plays**: each team's play types with possessions, share of possessions, points and
  points per possession, and every individual play (click to watch). For defenses (man,
  zone with its shape, press) the points are what the other team scored against it.
- **Data quality**: court mapped or not, jersey match rate, how often the ball was
  visible, warnings, and the jerseys that are not on a roster. Read it first: it tells
  you how much to trust this film.

### 6. The scouting report

On the **Scouting report** tab, optionally type a coach focus ("their press break",
"who takes the last shot"), then **Generate report**. It takes a few minutes. Versions
are kept; **Download .md** or **Print**. With `SCOUT_AUTO_REPORT=true` (the default)
a report is written automatically after each analysis when an API key is set. What is
sent to Claude: [Security and privacy](#security-and-privacy).

### 7. FastScout

The **Exports** tab:

- **FastScout paste block** for FastScout Classic: Stats > Edit Stats Database >
  Schedule > (game) > Goto Game > Box Score > Paste *Team* Data. One team per paste.
- **FastScout Web custom table (CSV)**: pick Box Score, Shot Zones, Play Types or
  Defensive Looks, download, and upload it to a Custom Table tile.
- **Timeline CSV** (Excel / Google Sheets) and **Analysis JSON** (everything).

Step-by-step instructions, name matching rules and caveats:
[docs/FASTSCOUT.md](docs/FASTSCOUT.md). The one-click **Copy** needs the site on
`https://`; otherwise use Download. Columns are set in `config/fastscout_columns.yaml`.

## Configuration reference

Everything is set in `.env` (start from `.env.example`, which lists every setting with
its default). Restart both services after a change:
`sudo systemctl restart basketball-scout-web basketball-scout-worker`.
`.env` lines must be plain `KEY=value`: no spaces around `=`, comments on their own
line, single quotes around values containing spaces, `#`, `$`, `\` or quotes (systemd
reads the same file).

**Server**

| Variable | Default | What it does |
|---|---|---|
| `SCOUT_HOST` | `0.0.0.0` | Listen address for `scout-web` (`make run-web` and `scripts/dev.sh` use their own `HOST`, 127.0.0.1; the systemd unit passes its own: 127.0.0.1 behind nginx) |
| `SCOUT_PORT` | `8000` | Listen port for `scout-web` (`make run-web` / `scripts/dev.sh`: `PORT=...`; on a server change it with `install.sh --port N`) |
| `SCOUT_LOG_LEVEL` | `info` | `debug`, `info`, `warning` or `error` |
| `SCOUT_DATA_DIR` | `data` | Games, film and database (relative to the repo). install.sh: `/var/lib/basketball-scout` |
| `SCOUT_DB_PATH` | `<data dir>/scout.db` | SQLite database file. On a server keep it inside the data folder: the services may write nowhere else |
| `SCOUT_PUBLIC_BASE_URL` | (none) | The address coaches use; for log messages only |
| `SCOUT_ENV_FILE` | `<repo>/.env` | Environment variable only: read settings from another file |

**Sign-in**

| Variable | Default | What it does |
|---|---|---|
| `SCOUT_AUTH_USERNAME` | `coach` | The coaches' username |
| `SCOUT_AUTH_PASSWORD` | (none) | Plain-text password (install.sh generates one) |
| `SCOUT_AUTH_PASSWORD_HASH` | (none) | Hash instead of a password, from `python -m scout.auth hash-password`; wins over the password |
| `SCOUT_AUTH_DISABLED` | `false` | `true` turns sign-in off. Trusted private networks only |
| `SCOUT_ALLOWED_HOSTS` | (none) | Host names the app answers to, comma-separated (`*.school.org` for its subdomains, `*` for any name); IP addresses and `localhost` always work. Empty: any name with sign-in on; with sign-in off only IP addresses, `localhost` and the server's own name |

**Uploads**

| Variable | Default | What it does |
|---|---|---|
| `SCOUT_MAX_UPLOAD_GB` | `12` | Largest film accepted |
| `SCOUT_UPLOAD_CHUNK_MB` | `16` | Size of each upload request; must stay below nginx's `client_max_body_size` (64m) |
| `SCOUT_MAX_VIDEO_MINUTES` | `150` | Longest film accepted (checked when `ffprobe` is installed) |

**Queue and worker**

| Variable | Default | What it does |
|---|---|---|
| `SCOUT_QUEUE_BACKEND` | `sqlite` | `sqlite` or `redis` |
| `SCOUT_REDIS_URL` | `redis://localhost:6379/0` | Redis server for the `redis` queue |
| `SCOUT_REDIS_PREFIX` | `scout` | Prefix of the Redis keys |
| `SCOUT_WORKER_CONCURRENCY` | `2` | Jobs one worker runs at once (1-16) |
| `SCOUT_JOB_LEASE_SECONDS` | `300` | A silent worker loses its job after this long; another worker resumes it |
| `SCOUT_JOB_MAX_ATTEMPTS` | `3` | Pickups before a job fails with `WORKER_LOST` |

**Video processing**

| Variable | Default | What it does |
|---|---|---|
| `SCOUT_PROCESSOR` | `modal` | `modal` (Modal GPU), `mock` (synthetic demo data) or `local` (this machine's NVIDIA GPU) |
| `MODAL_TOKEN_ID` | (none) | Modal token ID, read by the Modal SDK (overrides `~/.modal.toml`) |
| `MODAL_TOKEN_SECRET` | (none) | Modal token secret |
| `SCOUT_MODAL_APP_NAME` | `basketball-scout` | Deployed Modal app name |
| `SCOUT_MODAL_FUNCTION_NAME` | `process_video` | GPU function name |
| `SCOUT_MODAL_VOLUME_NAME` | `basketball-scout-data` | Modal Volume for film and results in transit |
| `SCOUT_MODAL_PROGRESS_DICT` | `basketball-scout-progress` | Modal Dict for progress |
| `SCOUT_MODAL_ENVIRONMENT` | (workspace default) | Modal environment the app runs in |
| `MODAL_ENVIRONMENT` | (workspace default) | The same for Modal commands you run yourself (`make deploy-modal`, `modal run`); `install.sh` / `update.sh` deploy into `SCOUT_MODAL_ENVIRONMENT` anyway. Set both together |
| `SCOUT_MODAL_POLL_SECONDS` | `10` | How often the worker checks a GPU job |
| `SCOUT_MODAL_MAX_WAIT_HOURS` | `8` | Give up waiting for a GPU job after this long (`MODAL_TIMEOUT`; not while Modal cannot be reached) |
| `SCOUT_MODAL_CLEANUP` | `true` | Delete film and results from the Modal Volume after download |
| `SCOUT_MODAL_GPU` | `A10G` | Deploy time: GPU type (redeploy after changing) |
| `SCOUT_MODAL_TIMEOUT_S` | `21600` | Deploy time: GPU time limit per film in seconds (max 86400). Above 8 hours also raise `SCOUT_MODAL_MAX_WAIT_HOURS` |
| `SCOUT_MODAL_MAX_CONTAINERS` | `2` | Deploy time: most GPU containers at once (cost cap) |
| `SCOUT_ANALYSIS_FPS` | `15` | Frames per second analysed (lower = cheaper, may miss quick plays) |
| `SCOUT_ANALYSIS_MAX_SIDE` | `1280` | Frames scaled so the longer side is at most this (320-3840) |
| `SCOUT_RENDER_ANNOTATED_VIDEO` | `true` | Render the annotated video |
| `SCOUT_RENDER_HEIGHT` | `720` | Annotated video height (240-2160) |
| `SCOUT_DETECTOR_WEIGHTS` | (built-in) | Custom detector checkpoint (path on the Modal Volume, or local) |
| `SCOUT_COURT_KEYPOINT_WEIGHTS` | (built-in) | Custom court keypoint checkpoint |
| `SCOUT_MOCK_SECONDS` | `8` | Pretend GPU time for `SCOUT_PROCESSOR=mock` |
| `OHV_HOME` | `/opt/openhoopvision` | `SCOUT_PROCESSOR=local` only: OpenHoopVision install folder |

**Claude report**

| Variable | Default | What it does |
|---|---|---|
| `ANTHROPIC_API_KEY` | (none) | Anthropic API key; without it there is no written report |
| `SCOUT_CLAUDE_MODEL` | `claude-opus-5-5` | Claude model |
| `SCOUT_CLAUDE_EFFORT` | `high` | `low`, `medium`, `high`, `xhigh` or `max`: thinking depth (and cost) |
| `SCOUT_CLAUDE_MAX_TOKENS` | `64000` | Output cap per report, thinking included (2048-128000) |
| `SCOUT_CLAUDE_FALLBACKS` | `true` | Let the API retry on a fallback model if Claude declines |
| `SCOUT_CLAUDE_TIMEOUT_S` | `900` | Seconds to wait for one report |
| `SCOUT_AUTO_REPORT` | `true` | Write a report automatically after each analysis |

**Config files**

| Variable | Default | What it does |
|---|---|---|
| `SCOUT_FASTSCOUT_CONFIG` | `config/fastscout_columns.yaml` | FastScout export columns |
| `SCOUT_COURT_CONFIG` | `config/court.yaml` | Court size and lines |
| `SCOUT_PLAY_RULES_CONFIG` | `config/play_rules.yaml` | Play recognition thresholds |

## Config files

All three are plain YAML (indent with spaces, not tabs) and documented inside. They
are part of the code checkout, so once you have edited one, update with
`sudo /opt/basketball-scout/scripts/update.sh --force`: it keeps your edits (see
[Update](#update)).

- **`config/court.yaml`**: court geometry in feet, NFHS defaults (84 x 50 ft,
  three-point line 19 ft 9 in). Many high school gyms are shorter (74-80 ft): set
  `length_ft` for the opponent's gym if you know it. It moves the half-court line and
  fast-break detection; shot zones are measured from the basket.
- **`config/play_rules.yaml`**: the thresholds behind every play detector (for example
  how close a screener must be for a pick and roll), plus `enabled: false` to switch a
  detector off. Delete a line to return to its default. Changes apply on the next
  **Re-run analysis**; no restart.
- **`config/fastscout_columns.yaml`**: which columns the FastScout paste block and CSV
  tables contain, header names, name format and play-type labels. Changes apply on the
  next export; no restart. See [docs/FASTSCOUT.md](docs/FASTSCOUT.md).

## Costs

**Modal (GPU).** The A10G list price is about **$1.10 per GPU hour**. The GPU function
also reserves 8 CPU cores and 32 GB of memory, which Modal bills separately (see
<https://modal.com/pricing>). A 60-minute game is expected to need roughly 1-3 GPU
hours; this has **not been measured yet**, so watch the usage page for your first
games. At that estimate the GPU part is roughly $1.10-$3.30 per game, plus the CPU and
memory time. Nothing runs between jobs, so an idle month costs nothing beyond storage.
The Starter plan includes $30 of credit per month. Ways to spend less: lower
`SCOUT_ANALYSIS_FPS`, set `SCOUT_RENDER_ANNOTATED_VIDEO=false`, keep
`SCOUT_MODAL_MAX_CONTAINERS` low, and set a budget alert in the Modal dashboard
([docs/DEPLOYMENT.md](docs/DEPLOYMENT.md#modal-cost-controls)).

**Claude (report).** List price for Claude Opus 5.5: **$4 per million input tokens and
$20 per million output tokens**. Claude's thinking counts as output. The game data is
sent as a cached block: the first request writes the cache (about 1.25 x the input
price) and a request that reuses it within a few minutes reads it at $0.20 per
million tokens. So one report costs:

```
cost = (uncached input x $4 + cache-write input x $5 + cache-read input x $0.20 + output x $20) / 1,000,000
```

With the defaults the game data is capped at roughly 25,000 tokens, plus a few thousand
tokens of instructions, and the output at `SCOUT_CLAUDE_MAX_TOKENS` = 64,000. That puts
an upper bound of about **$1.45 per report** at list prices; real reports finish below
the output cap (a report that hits it fails with `REPORT_TRUNCATED` and is still
billed). We have not measured typical token counts: the worker logs the approximate
payload size of each request, and the Anthropic Console shows the real usage. Lower
`SCOUT_CLAUDE_EFFORT` to `medium` for shorter, cheaper reports, or turn off
`SCOUT_AUTO_REPORT` so reports are written only on request.

**Server.** Your own hardware or VM. Plan disk space for film: roughly 3-8 GB per game
([docs/PROXMOX.md](docs/PROXMOX.md#storage-sizing)).

## Troubleshooting

Every error shown in the app has a code. Find it here:

| Code | What happened | What to do |
|---|---|---|
| `GPU_OOM` | The GPU ran out of memory, even after retrying with smaller batches. | Retry. If it repeats, lower `SCOUT_ANALYSIS_MAX_SIDE` (e.g. 960) or `SCOUT_ANALYSIS_FPS` (e.g. 10) in `.env` and restart the worker, or deploy a larger GPU with `SCOUT_MODAL_GPU` (costs more), or trim the film. |
| `MODAL_NOT_CONFIGURED` | No Modal credentials were found. | Add `MODAL_TOKEN_ID` / `MODAL_TOKEN_SECRET` to `.env` (or `modal token new` as the service user) and restart the worker. For a demo use `SCOUT_PROCESSOR=mock`. |
| `MODAL_AUTH_FAILED` | Modal rejected the token. | Create a new token in the Modal dashboard, update `.env`, restart the worker. |
| `MODAL_APP_NOT_DEPLOYED` | The GPU app or function was not found. | `sudo /opt/basketball-scout/scripts/update.sh --deploy-modal`. Check that `SCOUT_MODAL_APP_NAME` and the Modal environment match the deployment. |
| `MODAL_UPLOAD_FAILED` | The film could not be copied to the Modal Volume (the upload is tried three times). | Check the internet connection. School firewalls that inspect TLS traffic must let modal.com through untouched. Retry. |
| `MODAL_TIMEOUT` | The GPU job ran longer than `SCOUT_MODAL_TIMEOUT_S` (6 hours) or the worker waited longer than `SCOUT_MODAL_MAX_WAIT_HOURS` (8 hours). | Retry. For very long films raise `SCOUT_MODAL_TIMEOUT_S` (max 86400) and redeploy; above 8 hours also raise `SCOUT_MODAL_MAX_WAIT_HOURS` and restart the worker. Or split the film. |
| `MODAL_REMOTE_ERROR` | The GPU job crashed, or the server could not reach Modal (while a job runs, for 24 hours: "Lost contact with Modal for more than 24 hours"). | Check the server's internet connection, then Retry; details in `modal app logs basketball-scout`. |
| `MODAL_RESULT_EXPIRED` | The GPU result is no longer available (Modal keeps it 7 days) and its files are no longer on the volume. | Re-run the analysis. |
| `VIDEO_INVALID` | The file is not an MP4, MOV or M4V video. | Export the film as H.264 MP4 and upload again. |
| `VIDEO_DECODE_FAILED` | The video is corrupt or uses a codec that cannot be read. | Re-export as H.264 MP4 (for example with HandBrake) and upload again. |
| `VIDEO_TOO_LONG` | Longer than `SCOUT_MAX_VIDEO_MINUTES`. | Trim the film or raise the limit. |
| `VIDEO_DOWNLOAD_FAILED` | The GPU could not download the video link. | Use a direct link to the MP4 file (not a web page), or upload the file. |
| `VIDEO_MISSING` | The game has no film yet. | Upload an MP4 or add a video link. |
| `DETECTION_FAILED` | Too few players were found. | Use the wide game angle that shows the whole court, not close-ups or highlights. |
| `BALL_NOT_DETECTED` | The ball was found in too few frames. | Higher resolution (720p+) and less compressed film help. The box score may be incomplete. |
| `COURT_NOT_DETECTED` | The court lines were not found; shot zones are approximate. | For a fixed camera, calibrate the court on the game page and re-run the analysis. |
| `MODEL_LOAD_FAILED` | A model could not be loaded on the GPU. | Redeploy the GPU app and run `modal run modal_app/app.py::warmup`; check `SCOUT_DETECTOR_WEIGHTS` / `SCOUT_COURT_KEYPOINT_WEIGHTS`. |
| `PIPELINE_FAILED` | The computer-vision pipeline stopped with an error. | Retry; details in `modal app logs basketball-scout`. |
| `TRACKING_RESULT_INVALID` | The GPU output does not match this server version. | Deploy the matching GPU app: `sudo /opt/basketball-scout/scripts/update.sh --deploy-modal`. |
| `ANALYSIS_FAILED` | Building the box score or plays failed. | Click **Re-run analysis**. If it repeats, send the job id and `journalctl -u basketball-scout-worker -n 200` to IT. |
| `ANALYSIS_NOT_READY` | The game has not been analysed yet. | Wait for the job to finish. |
| `CALIBRATION_INVALID` | The clicked points do not give a usable court mapping. | Click at least 4 landmarks spread over the court, not all on one line. |
| `CONFIG_INVALID` | A settings file in `config/` (`play_rules.yaml`, `fastscout_columns.yaml`) has a typo or a wrong value type. | The message names the setting. Fix it, or restore the shipped file: `sudo -u scout git -C /opt/basketball-scout checkout -- config/<file>`. If the analysis failed, click **Re-run analysis** on the game page afterwards (no GPU). |
| `ROSTER_PARSE_FAILED` | No players could be read from the roster file. | Use a header row with a number column (#, No, Number) and a name column, or start from the roster template. |
| `ROSTER_UNSUPPORTED_FILE` | Not a `.csv`, `.tsv`, `.txt` or `.xlsx` file. | In Excel use File > Save As > Excel Workbook (.xlsx) or CSV. |
| `REPORT_NOT_CONFIGURED` | No Anthropic API key. | Add `ANTHROPIC_API_KEY` to `.env` and restart the worker. |
| `REPORT_AUTH_FAILED` | Anthropic rejected the key (401), or refused the request (403: the key's organisation may not use this model, or not from this region). | Check or replace `ANTHROPIC_API_KEY`; for a 403 check in the Anthropic Console that the key can use `SCOUT_CLAUDE_MODEL`. Restart the worker. |
| `REPORT_RATE_LIMITED` | The key hit Anthropic's rate limit. | Wait a minute and click **Generate report** again. |
| `REPORT_OVERLOADED` | The Anthropic API is busy. | Try again in a few minutes. |
| `REPORT_REFUSED` | Claude declined the request. | Remove unusual instructions from the coach focus box and try again. |
| `REPORT_TRUNCATED` | The report hit the output limit. | Raise `SCOUT_CLAUDE_MAX_TOKENS` (e.g. 96000), restart the worker, regenerate. |
| `REPORT_FAILED` | The report could not be written, or a web filter or proxy answered instead of Anthropic. | Try again; stats and exports still work. If a school filter blocks it, ask IT to allow `https://api.anthropic.com`. Details in the worker log. |
| `UPLOAD_TOO_LARGE` | The film is larger than `SCOUT_MAX_UPLOAD_GB`, the server's disk has no room for it, a roster file is over 2 MB, or nginx refused a request as too large. | Raise the limit (restart the web app), compress / trim the film, free disk space by deleting old games, or save just the roster as a CSV. Behind nginx keep `client_max_body_size 64m` (see `deploy/nginx`). |
| `UPLOAD_INCOMPLETE` | Part of the file did not arrive. | Retry the upload; it resumes where it stopped. |
| `UPLOAD_NOT_FOUND` | The upload session expired. | Start the upload again. |
| `REQUEST_TOO_LARGE` | A request was larger than the server accepts (1 MB of JSON, 4 MB for a roster file). | Send film with the upload page; keep roster files under 2 MB. |
| `NOT_FOUND`, `CONFLICT`, `VALIDATION_FAILED` | A missing item, a clash (e.g. an analysis already running) or invalid input. | The message names the problem. |
| `JOB_CANCELLED` | The GPU run was stopped outside Basketball Scout (for example cancelled in the Modal dashboard, or the local GPU run was stopped). | Start it again on the game page: **Analyze film**, or **Full re-analysis** for a game analysed before. |
| `WORKER_LOST` | The worker stopped during this job too many times. | Check `journalctl -u basketball-scout-worker` (and `journalctl -k \| grep -i oom` for memory), then Retry. |
| `QUEUE_UNAVAILABLE` | Redis could not be reached. | `sudo systemctl start redis-server`, or set `SCOUT_QUEUE_BACKEND=sqlite`. |
| `INTERNAL_ERROR` | Something unexpected went wrong. | Retry; if it repeats, check the logs. |

Sign-in problems: **"Sign-in is not set up"** (HTTP 503, `AUTH_NOT_CONFIGURED`) means
`.env` has no `SCOUT_AUTH_PASSWORD` or hash; **"Too many sign-in attempts"** (429)
clears itself after 5 minutes (or restart the web app); **"Request blocked"** (403,
`CROSS_SITE_REQUEST`) means a change was sent from a page on another website: open
Basketball Scout directly (type its address or use a bookmark) and try again; **"Unknown
server name"** (403, `HOST_NOT_ALLOWED`) means the address you typed is not in
`SCOUT_ALLOWED_HOSTS` (with sign-in off, add the name you use there, or use the
server's IP address). Forgot the password? `sudo grep SCOUT_AUTH_PASSWORD /opt/basketball-scout/.env`, or set a new
one and `sudo systemctl restart basketball-scout-web`.

**Uploads fail with "413 Request Entity Too Large".** That page comes from nginx (or
another proxy), not from the app: the body limit is smaller than one upload chunk. In
`/etc/nginx/sites-available/basketball-scout` keep `client_max_body_size 64m;` (it must
be bigger than `SCOUT_UPLOAD_CHUNK_MB`, 16 MB), then
`sudo nginx -t && sudo systemctl reload nginx`. A school proxy or firewall in front of
the server may need the same change.

**Jobs stay "Queued".** The worker is not running. The game page says so under the
queued job, and the **System status** card on the Games page shows when it was last seen. Check
`systemctl status basketball-scout-worker` and
`journalctl -u basketball-scout-worker -n 100`, then
`sudo systemctl restart basketball-scout-worker`. With Redis, also check
`systemctl status redis-server`.

**nginx shows "502 Bad Gateway".** The web app is down:
`systemctl status basketball-scout-web` and `journalctl -u basketball-scout-web -n 100`.

**A service fails with `status=226/NAMESPACE`** or logs "Read-only file system". The
data folder or the service user's home is missing, or `SCOUT_DATA_DIR` was changed by
hand. Run `sudo scripts/install.sh --data-dir <the folder>` again; it recreates the
folders and the units.

**The services do not start after a reboot ("Dependency failed").** The disk that holds
the data folder is not mounted: check `findmnt /var/lib/basketball-scout` and
`/etc/fstab`. The services wait for that mount instead of starting an empty database on
the system disk.

**Video does not seek.** The app answers HTTP Range requests; a proxy in front must
pass them through (the nginx template does). Try the address without the proxy.

**Copy to clipboard does nothing.** Browsers allow it only over `https://`; use
Download, or set up HTTPS.

## Accuracy: what to trust

- **The numbers are estimates.** They come from computer vision on one camera angle.
  Use them to find what to watch, then confirm it on film before you build a game plan
  on it. Minutes, rebounds, assists and play types are the least reliable; made shots
  and points are usually the most reliable.
- **Unknown players.** Jersey numbers are often unreadable (motion blur, angle, low
  resolution). Stats that cannot be tied to a player go to the team line; fix jersey
  assignments on the Roster page and re-run the analysis.
- **OpenHoopVision is young.** The pinned version is from October 2026, about two
  weeks after the project appeared, and its models were trained mostly on footage that
  is not high school game film. Dark gyms, crowd movement, similar jersey colours and
  low camera positions all reduce accuracy.
- **High school courts are not NBA courts.** OpenHoopVision's court model is NBA-sized
  (94 ft, 23 ft 9 in three). The pipeline adapts it to `config/court.yaml` (84 ft,
  NFHS 19 ft 9 in three by default), and the server classifies shots with the high
  school lines. Gyms vary in length, so set `length_ft` when you know it.
- **Play recognition is rule-based.** It labels what the tracking suggests (thresholds
  in `config/play_rules.yaml`); expect missed and mislabelled plays, more so when the
  court was not mapped.
- **Free throws need the court mapped.** Without court positions the pipeline cannot
  tell a free throw from a field goal: FTA shows 0 and each free throw counts as a
  2-point attempt. Calibrate and run a full re-analysis (see Court calibration).
- **Periods are inferred.** Quarter breaks and full timeouts look alike on film. The
  pipeline takes the longest stoppage (5 minutes or more) as halftime and one stoppage
  per half as the quarter break; other long stoppages show as timeouts. Overtime is
  not split off.
- **ID swaps.** When two players cross and the tracker swaps their ids, the rest of
  that track's stats go to the wrong player. A track is assigned as a whole; the app
  cannot split one yet.
- **Check the Data quality tab** for every game: court mapped, jersey match rate and
  ball visibility tell you how far to trust that particular film.

## Security and privacy

The system stores film, names and jersey numbers of high school students, including
other schools' players. Treat it like other student data and follow your school's or
district's data-privacy policy.

- **Keep it off the open internet.** Run it on the school network or behind a VPN
  (Tailscale, WireGuard). Do not port-forward it.
- **Use HTTPS.** HTTP basic auth sends the password with every request, readable on the
  network over plain `http://`. Either run `install.sh --with-nginx --domain NAME` and
  then `sudo certbot --nginx -d NAME` (needs a public DNS name and port 80 reachable
  from the internet; otherwise use a DNS challenge or your school's own certificate), or
  use Tailscale: install it on the server, `sudo tailscale up`, then
  `sudo tailscale serve --bg 8000` gives an `https://<server>.<tailnet>.ts.net` address
  with a certificate, reachable only from your tailnet. Details:
  [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md#tls-https).
- **Strong password.** install.sh generates a random one. To change it, edit
  `SCOUT_AUTH_PASSWORD` in `.env` (or store a hash from
  `cd /opt/basketball-scout && .venv/bin/python -m scout.auth hash-password` in
  `SCOUT_AUTH_PASSWORD_HASH`, in single quotes; run it from the code folder as shown,
  the only place Python finds the app) and restart the web app. Ten wrong passwords
  from one address within 5 minutes lock that address out for 5 minutes (thirty from
  one IPv6 /64 network lock out that network). Changes sent from another website's
  pages are refused. Only use `SCOUT_AUTH_DISABLED=true` on a network you fully trust.
- **Secrets** live in `.env` (mode 600, readable by root and `scout`). Never commit it
  (it is in `.gitignore`). The Modal token can run GPU jobs on your bill and the
  Anthropic key can spend money: revoke and replace them if they leak.
- **Retention.** Film and results stay until you delete the game (the Games page
  deletes the film, video and data). Delete past seasons you no longer need. Backups
  contain the film too: encrypt them and let them expire.
- **What leaves the server:**
  - **To Modal** (your own Modal workspace): the film file and its name, and the
    processing options (frame rate, court size, optional calibration, jersey-colour
    hint). No rosters or names. The film and results on the Modal Volume are deleted
    after download (`SCOUT_MODAL_CLEANUP=true`).
  - **To Anthropic**, only when a report is generated: team names, the game date,
    location and level, player names and jersey numbers from your rosters, the box
    score, play and event summaries, data-quality notes and the coach focus text. No
    video or images. See Anthropic's commercial terms and privacy policy for how API
    data is handled.
  - **To GitHub and PyPI**: nothing but downloads during install and update.
- **On the server** the services run as the unprivileged `scout` user in a systemd
  sandbox (the code is read-only to them; they can write only the data folder and their
  home). Keep the OS patched (`unattended-upgrades` is on by default in Ubuntu) and use
  a firewall (`sudo ufw allow OpenSSH && sudo ufw allow 80/tcp && sudo ufw enable`).

## Project layout

```
scout/                 the app (Python package)
  main.py              FastAPI app (uvicorn scout.main:app)
  worker.py            background worker (python -m scout.worker)
  auth.py              basic auth, password hashes (python -m scout.auth hash-password)
  config.py            settings from .env;  errors.py  error codes and messages
  db.py, storage.py    SQLite database and per-game files
  api/                 HTTP routes;  static/  pages, JavaScript, CSS (no build step)
  jobs/                job queue (SQLite, Redis)
  processing/          Modal, local GPU and mock processors
  analysis/            teams, events, possessions, box score, plays, synthetic games
  roster/              roster import and jersey matching
  export/              FastScout paste block and CSV, timeline CSV
  reporting/           Claude report: payload, prompts, rendering
modal_app/             Modal GPU app (app.py) and the pipeline around OpenHoopVision
config/                court.yaml, play_rules.yaml, fastscout_columns.yaml
scripts/               install.sh, update.sh, uninstall.sh, dev.sh
deploy/                systemd unit templates, nginx site template
docs/                  ARCHITECTURE, TRACKING_SCHEMA, FASTSCOUT, PROXMOX, DEPLOYMENT
tests/                 pytest suite
.env.example           every setting with its default
Makefile               development shortcuts
```

## Running the tests

```bash
make test                         # or: .venv/bin/python -m pytest
.venv/bin/python -m pytest tests/test_ops.py    # just the scripts and deploy files
make lint                         # ruff (if installed) + bash syntax check
```

The tests need no GPU, no Modal or Anthropic account, no Redis and no network: they use
the mock processor, fakes and temporary folders, and never read your `.env`.

## Credits

- [OpenHoopVision](https://github.com/feifeifei85/OpenHoopVision) by feifeifei85: the
  computer-vision engine (detection, pose, court keypoints, tracking, jersey OCR). Used
  at a pinned commit. Its README says Apache-2.0, but that commit has no LICENSE file;
  confirm the licence with the author before redistributing it.
- [Modal](https://modal.com) for serverless GPUs, and [Anthropic](https://www.anthropic.com)
  for Claude.
- Open-source building blocks: FastAPI, Uvicorn, Pydantic, NumPy, RapidFuzz,
  openpyxl, PyTorch, FFmpeg, nginx, Redis and SQLite.

FastScout is a product of FastModel Sports; Hudl and MaxPreps are trademarks of their
owners. This project is not affiliated with any of them. Licence: proprietary,
Marquette Catholic High School (see `pyproject.toml`).
