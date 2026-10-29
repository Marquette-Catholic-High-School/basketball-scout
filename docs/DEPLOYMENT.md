# Running Basketball Scout in production

For school IT. Installing is covered in the [README](../README.md#install-on-an-ubuntu-server)
and the VM in [PROXMOX.md](PROXMOX.md); this page is about keeping it running: TLS,
backups, monitoring, logs, updates, scaling and cost control.

Paths below are the installer defaults: code in `/opt/basketball-scout`, settings in
`/opt/basketball-scout/.env`, data in `/var/lib/basketball-scout`, service user `scout`.

## Checklist

- [ ] Ubuntu 24.04 VM or server sized as in [PROXMOX.md](PROXMOX.md), security updates on.
- [ ] Installed with `sudo scripts/install.sh --with-nginx --domain <name>`.
- [ ] HTTPS works (certbot, the school's certificate or Tailscale); plain `http://`
      redirects to `https://`.
- [ ] The generated password is in the school's password manager and shared with coaches
      only. Not reachable from the internet, or only through a VPN.
- [ ] Modal: token set, GPU app deployed, `warmup` passes, budget alert set,
      `SCOUT_MODAL_MAX_CONTAINERS` chosen.
- [ ] Anthropic: API key set, monthly spend limit set in the Console.
- [ ] Backups scheduled **and a restore tested**.
- [ ] An uptime check on `/api/health/live` that alerts a person.
- [ ] Journal size capped (see [Log rotation](#log-rotation)).
- [ ] Update routine agreed: snapshot, `update.sh`, check, delete the snapshot.
- [ ] Data retention agreed: who deletes last season's games, and when.

## TLS (HTTPS)

Coaches sign in with HTTP basic auth, so the password travels with every request. Over
plain `http://` anyone on the network path can read it. Pick one:

**certbot (Let's Encrypt).** Needs a public DNS name pointing at the server and port 80
reachable from the internet for the challenge.

```bash
sudo scripts/install.sh --with-nginx --domain scout.myschool.org   # if not done yet
sudo apt-get install -y certbot python3-certbot-nginx
sudo certbot --nginx -d scout.myschool.org --redirect
sudo certbot renew --dry-run                                       # renewal is automatic
sudo ufw allow 443/tcp
```

certbot edits `/etc/nginx/sites-available/basketball-scout`; `install.sh` sees that and
leaves the file alone afterwards. After HTTPS works, you can add HSTS inside the
`listen 443` server block: `add_header Strict-Transport-Security "max-age=31536000" always;`

**A server only on the school network.** Do not open it to the internet just for a
certificate. Use a DNS-01 challenge (a certbot DNS plugin for your DNS provider), a
certificate from the school's internal CA (add `listen 443 ssl;`, `ssl_certificate` and
`ssl_certificate_key` to the nginx site), or Tailscale.

**Tailscale.** `curl -fsSL https://tailscale.com/install.sh | sh`, `sudo tailscale up`,
`sudo tailscale serve --bg 8000`. The app is then at
`https://<machine>.<tailnet>.ts.net` with an automatic certificate, for devices on your
tailnet only (enable MagicDNS and HTTPS certificates in the Tailscale admin console).

HTTPS also enables the one-click "Copy" of the FastScout paste block (browsers allow
clipboard access only on secure pages).

## Private GitHub repository

If the repository is private, the server needs read access. A read-only deploy key for
the `scout` user is the cleanest way; create the user first so its home exists:

```bash
sudo useradd --system --create-home --home-dir /home/scout --shell /usr/sbin/nologin \
  --user-group --comment "Basketball Scout service" scout
sudo -u scout -H mkdir -p -m 700 /home/scout/.ssh
sudo -u scout -H ssh-keygen -t ed25519 -N "" -f /home/scout/.ssh/id_ed25519
sudo cat /home/scout/.ssh/id_ed25519.pub     # GitHub: repo Settings > Deploy keys > Add (read-only)
sudo -u scout -H ssh -o StrictHostKeyChecking=accept-new -T git@github.com   # trust GitHub's host key
sudo scripts/install.sh --repo git@github.com:Marquette-Catholic-High-School/basketball-scout.git
```

(Keep the `--comment` exactly as shown: `uninstall.sh --remove-user` only deletes a user
with that description.) A token in an `https://<token>@github.com/...` URL also works,
but it is stored in `/opt/basketball-scout/.git/config`, readable by local users.

## Backups

What to back up (the code itself is on GitHub):

| What | Where | Notes |
|---|---|---|
| Database | `/var/lib/basketball-scout/scout.db` | games, jobs, rosters, reports |
| Game files | `/var/lib/basketball-scout/games/` | film, annotated video, tracking, analysis |
| Settings and secrets | `/opt/basketball-scout/.env` | password, Modal token, Anthropic key |
| Modal token file (if used) | `/home/scout/.modal.toml` | only with `modal token new` |
| Your edits to `config/*.yaml` | `/opt/basketball-scout/config/` | only if you changed them |

**Option A: whole-VM backups** with vzdump or Proxmox Backup Server, see
[PROXMOX.md](PROXMOX.md#backups). Simplest to restore.

**Option B: a nightly script inside the VM**, to a network share or a USB disk. Save it
as `/usr/local/sbin/basketball-scout-backup` (mode 700) and add
`30 2 * * * /usr/local/sbin/basketball-scout-backup` to root's crontab (`sudo crontab -e`):

```bash
#!/usr/bin/env bash
set -euo pipefail
DEST=/mnt/backup/basketball-scout          # mounted share or disk
DATA=/var/lib/basketball-scout
STAMP=$(date +%F)
mkdir -p "$DEST/db" "$DEST/data" "$DEST/env"
# SQLite's online backup: a consistent copy while the app keeps running.
sqlite3 "$DATA/scout.db" ".backup '$DEST/db/scout-$STAMP.db'"
rsync -a --delete --exclude 'scout.db*' --exclude 'uploads/' "$DATA/" "$DEST/data/"
install -m 600 /opt/basketball-scout/.env "$DEST/env/env-$STAMP"
find "$DEST/db" "$DEST/env" -type f -mtime +30 -delete      # keep 30 days
```

The backups hold film and names of students: keep them encrypted and access-controlled
like the server, and let old copies expire. The `data/` copy is a mirror (`--delete`):
film of a game deleted on the server is gone from it the next night, while the database
copies go back 30 days. Use whole-VM backups (Option A) if you need older film back.

## Restoring from a backup

**Whole VM:** restore the vzdump/PBS backup in the Proxmox web UI (or `qmrestore`).

**Data only, on the same or a new server:**

```bash
# 1. Install the app if this is a new server, with the same data folder as before.
sudo scripts/install.sh --with-nginx --data-dir /var/lib/basketball-scout -y
# 2. Stop both services.
sudo systemctl stop basketball-scout-worker basketball-scout-web
# 3. Put the files back. Remove stale WAL files: they belong to the old database.
sudo rsync -a /mnt/backup/basketball-scout/data/ /var/lib/basketball-scout/
sudo cp /mnt/backup/basketball-scout/db/scout-2026-10-27.db /var/lib/basketball-scout/scout.db
sudo rm -f /var/lib/basketball-scout/scout.db-wal /var/lib/basketball-scout/scout.db-shm
sudo install -m 600 -o scout -g scout /mnt/backup/basketball-scout/env/env-2026-10-27 /opt/basketball-scout/.env
sudo chown -R scout:scout /var/lib/basketball-scout
# 4. Start again; database migrations run at startup.
sudo systemctl start basketball-scout-web basketball-scout-worker
```

Open the Games page and check a game. Jobs that were running when the backup was made
either resume or fail with `MODAL_RESULT_EXPIRED`; click Retry.

**Moving the data folder** (e.g. to a bigger disk): stop both services,
`sudo rsync -a /var/lib/basketball-scout/ /srv/scout-data/`, then
`sudo scripts/install.sh --data-dir /srv/scout-data` (updates `.env` and the systemd
units and restarts), check the games, and only then delete the old folder.

## Monitoring

**Logs** (systemd journal):

```bash
journalctl -u basketball-scout-web -f                     # web app, follow
journalctl -u basketball-scout-worker -f                  # worker, follow
journalctl -u basketball-scout-web -u basketball-scout-worker --since today -p warning
systemctl status basketball-scout-web basketball-scout-worker
modal app logs basketball-scout                           # the GPU side (on Modal)
```

**Health endpoints:**

- `GET /api/health/live` (or `HEAD`) needs no sign-in and answers `{"status": "ok"}` while the web
  app runs. Point an uptime monitor (Uptime Kuma, the school's monitoring) at
  `https://scout.myschool.org/api/health/live`.
- `GET /api/health` needs the coaches' login and reports what works:
  `curl -u coach https://scout.myschool.org/api/health` (curl asks for the password).

| Field | Meaning |
|---|---|
| `status` | `ok`, or `degraded` when jobs cannot run (queue down, worker silent, Modal not configured) |
| `queue_ok` | the job queue (SQLite or Redis) answers |
| `worker_last_seen_s` | seconds since the worker's last heartbeat; over 120 means it is not running |
| `modal_configured`, `claude_configured` | credentials found |
| `ffmpeg_available` | `ffprobe` present for the upload length check |
| `processor`, `queue_backend`, `auth_enabled`, `version` | the running configuration |

The **System status** card on the Games page shows the same information.

**Disk:** `df -h /var/lib/basketball-scout` and, per game,
`sudo du -sh /var/lib/basketball-scout/games/* | sort -h | tail`. Act at about 80 % full.

**Spending:** Modal dashboard (usage per app) and the Anthropic Console (usage and
limits).

## Log rotation

Both services log to the systemd journal, which rotates itself by size. Cap it so it
never crowds out film:

```bash
sudo mkdir -p /etc/systemd/journald.conf.d
printf '[Journal]\nSystemMaxUse=2G\nMaxRetentionSec=3month\n' | sudo tee /etc/systemd/journald.conf.d/size.conf
sudo systemctl restart systemd-journald
```

nginx writes `/var/log/nginx/*.log`, rotated daily by logrotate (14 days on Ubuntu).
The logs contain coaches' IP addresses and page addresses (game ids), never film or
passwords.

## Updates

- **Operating system:** security updates install automatically (`unattended-upgrades`).
  Reboot when `/var/run/reboot-required` exists, outside game-film evenings.
- **Basketball Scout**, by hand, when nobody is uploading:

  ```bash
  qm snapshot <vmid> before-update-$(date +%Y%m%d)       # on the Proxmox host
  sudo /opt/basketball-scout/scripts/update.sh           # in the VM
  # check the Games page, then delete the snapshot: qm delsnapshot <vmid> before-update-YYYYMMDD
  ```

  `update.sh` installs new requirements, runs database migrations, redeploys the GPU
  app when its code changed, restarts the services and checks them. When something fails
  it prints the commands that return to the previous version. GPU jobs running on Modal
  carry on during the restart. With `SCOUT_PROCESSOR=local` a film being processed is
  lost on restart, so update between runs.
- If `update.sh` says the `deploy/` templates changed, run `sudo scripts/install.sh`
  again to apply them; it keeps settings and data.
- Automatic app updates from cron are not recommended: an update can include a Modal
  redeploy and deserves a quick look afterwards.

## Scaling

The web app is light; the heavy computer vision runs on Modal.

- **One web process.** Keep the web unit's single uvicorn process (no `--workers`): the
  sign-in lockout, remembered logins, the key that signs the `scout_device` cookies, the
  per-upload locks that keep resumed upload chunks in order and the lock that stops a
  double click from starting two analyses live in that process's memory. A second
  uvicorn process would not recognise the first one's device cookies.
- **More films at once:** raise `SCOUT_WORKER_CONCURRENCY` (default 2, max 16; restart
  the worker) together with `SCOUT_MODAL_MAX_CONTAINERS` (default 2; redeploy). A
  running job mostly waits on the GPU, but the analysis step after it runs on this
  server's CPU and memory, so keep concurrency below the number of cores and watch memory
  the first time several full games finish together.
- **Redis and several workers:** `sudo scripts/install.sh --with-redis`, then add worker
  processes on the same machine by copying the unit with its own worker id:

  ```bash
  sudo cp /etc/systemd/system/basketball-scout-worker.service /etc/systemd/system/basketball-scout-worker2.service
  sudo sed -i 's|-m scout.worker$|-m scout.worker --worker-id worker2|' /etc/systemd/system/basketball-scout-worker2.service
  sudo systemctl daemon-reload && sudo systemctl enable --now basketball-scout-worker2
  ```

  (`install.sh` and `uninstall.sh` manage only the two standard units; remove copies
  yourself.) The SQLite queue also handles several workers; Redis just hands out jobs
  faster. Keep all workers on the server itself: they share the SQLite database and the
  data folder, and SQLite over network storage is not reliable.
- **Local GPU** (`SCOUT_PROCESSOR=local`): one film at a time.

## Modal cost controls

- **GPUs at once:** `SCOUT_MODAL_MAX_CONTAINERS` (default 2) sets `max_containers` on the
  `process_video` function. Put it in `.env` and redeploy
  (`sudo /opt/basketball-scout/scripts/update.sh --deploy-modal`).
- **Time per film:** `SCOUT_MODAL_TIMEOUT_S` (default 6 hours) stops a runaway job;
  `SCOUT_MODAL_MAX_WAIT_HOURS` (default 8) is the worker's own limit, counted from the
  start of the job (upload included); when it runs out the worker cancels the GPU call
  (not while Modal cannot be reached at all: then it waits until 24 hours without
  contact). Raising `SCOUT_MODAL_TIMEOUT_S` above 8 hours therefore also needs a higher
  `SCOUT_MODAL_MAX_WAIT_HOURS`.
- **Less GPU time per film:** lower `SCOUT_ANALYSIS_FPS` (default 15), set
  `SCOUT_RENDER_ANNOTATED_VIDEO=false`, and keep `SCOUT_MAX_VIDEO_MINUTES` tight so
  over-long uploads are refused before they reach the GPU. Changing these needs only a
  worker restart.
- **Budget:** in the Modal dashboard, set a budget alert or spending limit for the
  workspace in the billing settings. The Starter plan includes $30 of credit per month.
- **Watch:** the dashboard's usage page per app; `modal app logs basketball-scout`.
- **Stop a job:** the game page's Cancel button cancels the Modal call. As a last resort
  `modal app stop basketball-scout -y` stops everything; new films then fail with
  `MODAL_APP_NOT_DEPLOYED` until you redeploy.

## Security notes

- Services run as `scout` with systemd sandboxing: the code folder is read-only to them,
  they can write only the data folder and `/home/scout`. `systemd-analyze security
  basketball-scout-web` shows the details.
- `.env` is mode 600 (root and `scout`). Rotate the coaches' password at the start of each
  season: edit `SCOUT_AUTH_PASSWORD` (or `SCOUT_AUTH_PASSWORD_HASH`) and restart the web
  app.
- Keep the server off the public internet; use HTTPS; see the README's
  [Security and privacy](../README.md#security-and-privacy) section for what data goes to
  Modal and Anthropic.
