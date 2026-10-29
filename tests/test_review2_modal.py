"""Regression tests from the second review of the GPU pipeline and the local processor.

Each test pins a defect found in review: every full timeout more than 4 minutes into a
quarter became a period break, free throws silently counted as field goals on films
without court positions, invented team colours, link errors that crashed or were retried,
the local processor downloading from the server's own network (SSRF), an old OHV clone
that could not check out a newly pinned commit, cover-art streams, an unreadable
VIDEO_TOO_LONG message and relative custom weights that OHV resolved elsewhere.
"""

from __future__ import annotations

import io
import json
import math
import os
import shutil
import socket
import subprocess
from pathlib import Path
from types import SimpleNamespace

import numpy as np
import pytest

from modal_app.pipeline import adapter, errors, ohv, result, runner, video
from modal_app.pipeline.errors import PipelineError
from modal_app.pipeline.events import detect_events
from modal_app.pipeline.types import BallObs, Perception, TrackData, TrackObs, VideoMeta
from modal_app.pipeline.video import FrameMap, VideoProbe
from scout.analysis import pipeline
from scout.analysis.plays import PlayRules
from scout.analysis.teams import resolve_team_map
from scout.errors import ErrorCode
from scout.processing.base import VideoSource
from scout.processing.local import LocalProcessor
from scout.schemas import EventType, Game, TeamSide, TrackingResult
from tests.test_modal_events import ev, free_throw_trip, of_type
from tests.test_modal_pipeline import _FakeOhv, _fake_ohv_home, _FakeResponse, _serve
from tests.test_processing_mock_local import _wait_until_finished

FIXTURE = Path(__file__).parent / "fixtures" / "ohv_game.jsonl"  # 20 analysed frames at 15 fps, with court positions


# ---------------------------------------------------------------------------
# 1. Periods and timeouts (docs/TRACKING_SCHEMA.md "Periods and timeouts")
# ---------------------------------------------------------------------------

FPS, STEP = 30.0, 10  # 3 analysed frames per second keep a 54-minute game small
PLAYERS = (1, 2, 3, 4, 5, 11, 12, 13, 14, 15)


def game_film(*segments: tuple[str, float]) -> Perception:
    """Ten players and the ball through ``("live", s)`` / ``("stop", s)`` segments. Live:
    everyone on the floor and the ball held, changing teams every 20 s. Stop: everyone at
    the bench (off the court) and no ball, like a timeout or a break."""
    edges = np.cumsum([0.0] + [seconds for _, seconds in segments])
    frames = int(round(edges[-1] * FPS))
    meta = VideoMeta(
        path="film.mp4", filename="film.mp4", fps=FPS, width=1920, height=1080, frame_count=frames,
        duration_s=float(edges[-1]), analysis_fps=FPS / STEP, step=STEP,
    )  # fmt: skip
    p = Perception(video=meta, court_length_ft=84.0, court_width_ft=50.0)
    obs: dict[int, list[TrackObs]] = {tid: [] for tid in PLAYERS}
    for k in range(frames // STEP):
        t = k * STEP / FPS
        live = segments[int(np.searchsorted(edges, t, side="right")) - 1][0] == "live"
        for i, tid in enumerate(PLAYERS):
            on_court = (20 + 5 * i + 3 * math.sin(t / 7 + i), 10 + 3 * i + 3 * math.cos(t / 5 + i))
            x, y = on_court if live else (30 + 2 * i, -5)  # the bench is off the court
            fx, fy = 60 + 20 * x, 1060 - 20 * y
            obs[tid].append(TrackObs(frame=k * STEP, bbox=(fx - 20, fy - 120, fx + 20, fy), conf=0.9, court_xy=(x, y)))
        if live:
            holder = PLAYERS[5 * (int(t // 20) % 2) + int(t // 4) % 5]
            hx, hy = obs[holder][-1].court_xy  # type: ignore[misc]
            xy = (60 + 20 * hx, 1060 - 20 * (hy + 3.5))
            p.ball.append(BallObs(frame=k * STEP, xy=xy, conf=0.9, court_xy=(hx, hy), holder_track_id=holder))
    for tid in PLAYERS:
        p.tracks[tid] = TrackData(track_id=tid, obs=obs[tid], team_id=0 if tid < 10 else 1)
    return p


FULL_GAME = (
    ("live", 250), ("stop", 60), ("live", 290),  # Q1 with a full timeout 250 s in
    ("stop", 90),  # quarter break at 600 s
    ("live", 300), ("stop", 60), ("live", 240),  # Q2, timeout at 990 s
    ("stop", 600),  # halftime at 1290 s
    ("live", 280), ("stop", 60), ("live", 260),  # Q3, timeout at 2170 s
    ("stop", 90),  # quarter break at 2490 s
    ("live", 450), ("stop", 60), ("live", 90),  # Q4, timeout at 3030 s
    ("stop", 60),  # the teams leave: the film ends at 3240 s
)  # fmt: skip


def periods(extra: list[dict]) -> tuple[list[tuple[int, int]], list[tuple[int, int]], list[int]]:
    """(period, t) of the starts and ends, and the t of the timeouts, rounded to seconds."""
    starts = [(e["attrs"]["period"], round(e["t"])) for e in of_type(extra, "period_start")]
    ends = [(e["attrs"]["period"], round(e["t"])) for e in of_type(extra, "period_end")]
    return starts, ends, [round(e["t"]) for e in of_type(extra, "timeout")]


def test_a_full_game_has_four_periods_and_its_timeouts_stay_timeouts():
    extra = detect_events(game_film(*FULL_GAME))
    starts, ends, timeouts = periods(extra)
    assert starts == [(1, 0), (2, 690), (3, 1890), (4, 2580)]
    assert ends == [(1, 600), (2, 1290), (3, 2490), (4, 3180)]  # the last: the stoppage that ends the film
    assert timeouts == [250, 990, 2170, 3030]
    for timeout in of_type(extra, "timeout"):
        assert timeout["team_id"] is None and timeout["track_id"] is None
        assert timeout["attrs"] == {"inferred": True}
        assert 0.4 <= timeout["conf"] < 0.5  # 60 s: conf from the duration, as for any stoppage


def test_the_longest_long_stoppage_is_halftime_and_a_long_delay_is_a_timeout():
    """A 6-minute injury delay in Q2 is a long stoppage too, but halftime is the longest."""
    game = list(FULL_GAME)
    game[5] = ("stop", 360)
    starts, ends, timeouts = periods(detect_events(game_film(*game)))
    assert [t for _, t in starts] == [0, 690, 2190, 2880] and [t for _, t in ends] == [600, 1590, 2790, 3480]
    assert timeouts == [250, 990, 2470, 3330]


def test_one_half_with_timeouts_has_two_periods():
    one_half = (
        ("stop", 120),  # the film opens before the tip: not a timeout
        ("live", 300), ("stop", 60), ("live", 240),  # Q1, timeout at 420 s
        ("stop", 90),  # quarter break at 720 s
        ("live", 200), ("stop", 60), ("live", 340),  # Q2, timeout at 1010 s; the film ends during play
    )  # fmt: skip
    starts, ends, timeouts = periods(detect_events(game_film(*one_half)))
    assert starts == [(1, 120), (2, 810)] and ends == [(1, 720)]
    assert timeouts == [420, 1010]


def test_a_film_with_only_timeouts_is_one_period():
    """No halftime-length stoppage, and none in the middle with 7 minutes of play on each side."""
    only_timeouts = (
        ("live", 150), ("stop", 50), ("live", 150), ("stop", 70), ("live", 400), ("stop", 60), ("live", 140),
    )  # fmt: skip
    starts, ends, timeouts = periods(detect_events(game_film(*only_timeouts)))
    assert starts == [(1, 0)] and ends == []
    assert timeouts == [150, 350, 820]


def test_an_early_timeout_is_a_timeout_event_and_is_not_duplicated():
    early = (("live", 30), ("stop", 60), ("live", 500), ("stop", 90), ("live", 540))
    film = game_film(*early)
    extra = detect_events(film)
    starts, ends, timeouts = periods(extra)
    assert starts == [(1, 0), (2, 680)] and ends == [(1, 590)]
    assert timeouts == [30]
    # A timeout the pipeline already has inside that stoppage is not added again.
    existing = [ev("t1", "timeout", 50.0, team=1)]
    assert of_type(detect_events(film, existing_events=existing), "timeout") == []


def test_inferred_periods_and_timeouts_reach_the_timeline():
    """Pipeline events -> tracking.json.gz -> analyze_game: TIMEOUT rows, four periods."""
    film = game_film(*FULL_GAME)
    events = runner.merge_events(film, [])
    info = {"name": "openhoopvision", "version": "test", "models": {}, "options": {}}
    raw = result.build_tracking_result(film, events, job_id="j_1", pipeline_info=info)
    tracking = TrackingResult.model_validate(raw)
    analysis = pipeline.analyze_game(tracking, Game(scouted_team="Central", other_team="North"), {}, rules=PlayRules())
    rows = analysis.timeline
    assert [r.label for r in rows if r.type == EventType.PERIOD_START] == [f"Start of Period {n}" for n in (1, 2, 3, 4)]
    assert [round(r.t) for r in rows if r.type == EventType.PERIOD_END] == [600, 1290, 2490, 3180]
    assert [round(r.t) for r in rows if r.type == EventType.TIMEOUT] == [250, 990, 2170, 3030]


# ---------------------------------------------------------------------------
# 2. FREE_THROWS_NOT_DETECTED
# ---------------------------------------------------------------------------


def _free_throw_warnings(perception: Perception) -> list[dict[str, str]]:
    return [w for w in perception.warnings if w["code"] == "FREE_THROWS_NOT_DETECTED"]


def test_free_throws_skipped_for_lack_of_court_positions_are_reported():
    shot = ev("e1", "shot", 10.0, track=1, team=0, made=False)
    unmapped = free_throw_trip(court=False)
    runner.merge_events(unmapped, [shot])
    runner.merge_events(unmapped, [shot])  # once per run, however often it is checked
    (warning,) = _free_throw_warnings(unmapped)
    assert warning["severity"] == "warning" and "free throw" in warning["message"]
    assert "2-point attempt" in warning["message"] and "Full re-analysis" in warning["message"]
    mapped = free_throw_trip(court=True)
    merged = runner.merge_events(mapped, [shot])
    assert _free_throw_warnings(mapped) == [] and of_type(merged, "free_throw")


@pytest.fixture
def fake_gpu(monkeypatch, tmp_path):
    """run_pipeline with fake ffprobe / ffmpeg / OHV; OHV "writes" ``state.jsonl``."""
    state = SimpleNamespace(jsonl=FIXTURE)

    def probe(path):
        return VideoProbe(
            path=str(path), fps=30.0, fps_rational="30/1", width=1920, height=1080, duration_s=40 / 30,
            frame_count=40, codec="h264",
        )  # fmt: skip

    def transcode(src, dst, plan, *, progress=None):
        Path(dst).write_bytes(b"analysis copy")
        return Path(dst)

    def run_ohv(video_path, work_dir, **kwargs):
        work = Path(work_dir)
        work.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(state.jsonl, work / "ohv_tracks.jsonl")
        return ohv.OhvRun(
            tracks_path=work / "ohv_tracks.jsonl", events_path=work / "ohv_events.json", output_video=None,
            params=ohv.OhvParams(), attempts=1, summary=ohv.OhvSummary(),
        )  # fmt: skip

    monkeypatch.setattr(video, "probe_video", probe)
    monkeypatch.setattr(video, "check_decodable", lambda path: None)
    monkeypatch.setattr(video, "transcode_for_analysis", transcode)
    monkeypatch.setattr(ohv, "run_ohv", run_ohv)
    monkeypatch.setattr(ohv, "gpu_name", lambda: None)
    return state


def _pipeline_warnings(tmp_path: Path) -> list[dict[str, str]]:
    film = tmp_path / "film.mp4"
    film.write_bytes(b"film")
    (tmp_path / "scratch").mkdir(exist_ok=True)
    opts = {"render_video": False, "work_dir": str(tmp_path / "scratch")}
    response = runner.run_pipeline(str(film), opts, output_dir=str(tmp_path / "out"), job_id="j_1")
    assert response["status"] == "ok", response
    return response["warnings"]


def test_a_film_without_court_positions_warns_that_free_throws_count_as_field_goals(fake_gpu, tmp_path):
    assert "FREE_THROWS_NOT_DETECTED" not in {w["code"] for w in _pipeline_warnings(tmp_path)}  # court mapped
    records = [json.loads(line) for line in FIXTURE.read_text().splitlines() if line.strip().endswith("}")]
    for record in records:
        for player in record.get("players") or []:
            player.pop("court_xy", None)
    fake_gpu.jsonl = tmp_path / "unmapped.jsonl"
    fake_gpu.jsonl.write_text("".join(json.dumps(r) + "\n" for r in records))
    codes = [w["code"] for w in _pipeline_warnings(tmp_path)]
    assert codes.count("FREE_THROWS_NOT_DETECTED") == 1 and "NO_COURT_HOMOGRAPHY" in codes


# ---------------------------------------------------------------------------
# 3. Team colours OHV did not report are not invented
# ---------------------------------------------------------------------------


def test_missing_team_colours_are_compared_by_brightness_not_with_made_up_greys():
    adapted = adapter.adapt_ohv(FIXTURE, _fixture_meta(), FrameMap.identity(15.0))  # no "team colors" line
    assert [(t["color_rgb"], t["color_name"]) for t in adapted.perception.teams] == [(None, "dark"), (None, "light")]
    info = {"name": "openhoopvision", "version": "test"}
    tracking = TrackingResult.model_validate(
        result.build_tracking_result(adapted.perception, adapted.events, job_id="j", pipeline_info=info)
    )
    assert [t.color_rgb for t in tracking.teams] == [None, None]
    # Orange is a light colour: with fake (40, 40, 40) / (235, 235, 235) it was nearer the dark grey.
    team_map = resolve_team_map(tracking, Game(scouted_team="Central", scouted_color="orange"))
    assert team_map[1] == TeamSide.SCOUTED and team_map[0] == TeamSide.OTHER


def _fixture_meta() -> VideoMeta:
    return VideoMeta(
        path="game.mp4", filename="game.mp4", fps=15.0, width=1280, height=720, frame_count=20, duration_s=20 / 15,
        analysis_fps=15.0, step=1, codec="h264",
    )  # fmt: skip


# ---------------------------------------------------------------------------
# 4. Links that are not valid web addresses
# ---------------------------------------------------------------------------


@pytest.fixture
def no_network(monkeypatch):
    """Fail on any real connection; record download attempts (a retry is a second one)."""
    attempts: list[str] = []
    download_once = video._download_once

    def refuse(*args, **kwargs):
        raise AssertionError(f"tried to connect: {args}")

    def counted(url, *args, **kwargs):
        attempts.append(url)
        return download_once(url, *args, **kwargs)

    monkeypatch.setattr(socket, "create_connection", refuse)
    monkeypatch.setattr(video, "_download_once", counted)
    return attempts


@pytest.mark.parametrize("public_only", [False, True])
@pytest.mark.parametrize(
    "url",
    [
        "https://films.example.org/finäl-game.mp4",  # http.client sends the path as ASCII: UnicodeEncodeError
        "http://films.example.org:80a/film.mp4",  # http.client.InvalidURL: nonnumeric port
        "http://films.example.org:99999/film.mp4",  # socket: OverflowError
        "http:///film.mp4",  # urllib: "no host given", retried as if the server were down
    ],
)
def test_an_invalid_link_fails_at_once_with_a_clear_message(no_network, tmp_path, url, public_only):
    with pytest.raises(PipelineError) as info:
        video.download_video(url, tmp_path / "dl" / "film.mp4", public_only=public_only)
    assert info.value.code == errors.VIDEO_DOWNLOAD_FAILED
    assert info.value.message == "The video link is not a valid web address."
    assert len(no_network) <= 1  # not retried
    assert not list((tmp_path / "dl").glob("*"))


def test_a_bad_content_length_is_treated_as_unknown(monkeypatch, tmp_path):
    """int("abc") used to escape as PIPELINE_FAILED (now it would read as an invalid link)."""
    _serve(monkeypatch, _FakeResponse(b"film", length="abc"))  # type: ignore[arg-type]
    assert video.download_video("https://example.org/f.mp4", tmp_path / "f.mp4").read_bytes() == b"film"


# ---------------------------------------------------------------------------
# 5. public_only downloads (the local processor downloads on the server)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("address", "public"),
    [
        ("93.184.216.34", True), ("2606:2800:220:1:248:1893:25c8:1946", True), ("::ffff:93.184.216.34", True),
        ("127.0.0.1", False), ("10.1.2.3", False), ("172.16.0.9", False), ("192.168.1.20", False),
        ("169.254.169.254", False), ("100.64.0.1", False), ("0.0.0.0", False), ("224.0.0.251", False),
        ("240.0.0.1", False), ("255.255.255.255", False), ("::1", False), ("fe80::1%en0", False),
        ("fd00::1", False), ("ff0e::1", False), ("::ffff:127.0.0.1", False), ("::ffff:10.0.0.1", False),
        ("64:ff9b::a00:1", False), ("not an address", False),
    ],
)  # fmt: skip
def test_only_global_unicast_addresses_count_as_public(address, public):
    assert video._is_public_address(address) is public


class _FakeSocket:
    """A connected socket that answers one HTTP request with ``reply``."""

    def __init__(self, reply: bytes) -> None:
        self.reply = reply
        self.sent = b""

    def setsockopt(self, *args):
        pass

    def sendall(self, data):
        self.sent += data

    def makefile(self, mode, *args, **kwargs):
        return io.BytesIO(self.reply)

    def close(self):
        pass


def _http(status: str, headers: dict[str, str], body: bytes = b"") -> bytes:
    lines = [f"HTTP/1.1 {status}", *(f"{k}: {v}" for k, v in headers.items()), f"Content-Length: {len(body)}"]
    return ("\r\n".join(lines) + "\r\n\r\n").encode() + body


@pytest.fixture
def fake_internet(monkeypatch):
    """Fake DNS (``dns[host]``: addresses, or a list of answers for successive lookups) and
    fake servers (``servers[ip]``: replies in order); records lookups and connections."""
    net = SimpleNamespace(dns={}, servers={}, lookups=[], connections=[], sleeps=[])
    real_getaddrinfo = socket.getaddrinfo

    def getaddrinfo(host, port, *args, **kwargs):
        net.lookups.append(host)
        answer = net.dns.get(host)
        if answer is None:  # IP literals resolve to themselves without DNS
            return real_getaddrinfo(host, port, *args, **kwargs)
        if answer and isinstance(answer[0], list):
            answer = answer.pop(0) if len(answer) > 1 else answer[0]
        return [(socket.AF_INET6 if ":" in a else socket.AF_INET, socket.SOCK_STREAM, 6, "", (a, port)) for a in answer]

    def create_connection(address, timeout=None, source_address=None, **kwargs):
        net.connections.append(address)
        replies = net.servers.get(address[0])
        if not replies:
            raise ConnectionRefusedError(f"nothing listens on {address}")
        return _FakeSocket(replies.pop(0))

    monkeypatch.setattr(socket, "getaddrinfo", getaddrinfo)
    monkeypatch.setattr(socket, "create_connection", create_connection)
    monkeypatch.setattr(video.time, "sleep", net.sleeps.append)
    monkeypatch.setenv("http_proxy", "http://10.0.0.99:3128")  # never used: the proxy would do its own lookup
    return net


def _refused(url: str, tmp_path: Path) -> PipelineError:
    with pytest.raises(PipelineError) as info:
        video.download_video(url, tmp_path / "dl" / "film.mp4", public_only=True)
    assert info.value.code == errors.VIDEO_DOWNLOAD_FAILED
    return info.value


@pytest.mark.parametrize(
    "url",
    [
        "http://127.0.0.1:6379/", "http://localhost:8765/api/games", "http://[::1]/film.mp4",
        "http://169.254.169.254/latest/meta-data/", "http://10.0.0.5/film.mp4", "http://0.0.0.0:6379/",
        "http://lan-nas.example.org/film.mp4", "http://mixed.example.org/film.mp4",
    ],
)  # fmt: skip
def test_public_only_refuses_links_into_the_servers_own_network(fake_internet, tmp_path, url):
    fake_internet.dns.update({
        "localhost": ["127.0.0.1", "::1"], "lan-nas.example.org": ["192.168.1.20"],
        "mixed.example.org": ["93.184.216.34", "10.0.0.5"],  # every address must be public
    })  # fmt: skip
    error = _refused(url, tmp_path)
    assert "private or local network" in error.message and "Upload the film file instead" in error.message
    assert fake_internet.connections == [] and fake_internet.sleeps == []  # never connected, never retried
    assert not list((tmp_path / "dl").iterdir())


def test_public_only_connects_to_the_address_it_checked(fake_internet, tmp_path):
    fake_internet.dns["films.example.org"] = [["93.184.216.34"], ["127.0.0.1"]]  # a second lookup would rebind
    fake_internet.servers["93.184.216.34"] = [_http("200 OK", {"Content-Type": "video/mp4"}, b"film")]
    dest = video.download_video("http://films.example.org/game.mp4", tmp_path / "game.mp4", public_only=True)
    assert dest.read_bytes() == b"film"
    assert fake_internet.lookups == ["films.example.org"] and fake_internet.connections == [("93.184.216.34", 80)]


@pytest.mark.parametrize(
    "location",
    [
        "http://169.254.169.254/latest/meta-data/",  # cloud metadata
        "http://films.example.org:6379/",  # the same name, which now resolves to 127.0.0.1 (DNS rebinding)
        "http://cdn.example.net/x.mp4",  # one of its addresses is on the LAN
        "ftp://films.example.org/film.mp4",  # urllib would follow ftp:// redirects
    ],
)
def test_public_only_checks_every_redirect(fake_internet, tmp_path, location):
    fake_internet.dns["films.example.org"] = [["93.184.216.34"], ["127.0.0.1"]]  # rebinds after the first lookup
    fake_internet.dns["cdn.example.net"] = ["8.8.4.4", "10.0.0.5"]
    fake_internet.servers["93.184.216.34"] = [_http("302 Found", {"Location": location})]
    fake_internet.servers["8.8.4.4"] = [_http("200 OK", {"Content-Type": "video/mp4"}, b"film")]
    _refused("http://films.example.org/game.mp4", tmp_path)
    assert fake_internet.connections == [("93.184.216.34", 80)]  # the redirect was never followed


def test_public_only_checks_the_address_it_connects_to_after_a_redirect(fake_internet, tmp_path):
    """The redirect target passed its check, then its name was rebound: the connection checks again."""
    fake_internet.dns.update({"films.example.org": ["93.184.216.34"], "cdn.example.net": [["8.8.4.4"], ["10.0.0.5"]]})
    fake_internet.servers["93.184.216.34"] = [_http("302 Found", {"Location": "http://cdn.example.net/x.mp4"})]
    fake_internet.servers["10.0.0.5"] = [_http("200 OK", {"Content-Type": "video/mp4"}, b"from the LAN")]
    _refused("http://films.example.org/game.mp4", tmp_path)
    assert fake_internet.lookups == ["films.example.org", "cdn.example.net", "cdn.example.net"]
    assert fake_internet.connections == [("93.184.216.34", 80)]


def test_public_only_follows_a_redirect_to_another_public_host(fake_internet, tmp_path):
    fake_internet.dns.update({"films.example.org": ["93.184.216.34"], "cdn.example.net": ["8.8.4.4"]})
    fake_internet.servers["93.184.216.34"] = [_http("302 Found", {"Location": "http://cdn.example.net/x.mp4"})]
    fake_internet.servers["8.8.4.4"] = [_http("200 OK", {"Content-Type": "video/mp4"}, b"film")]
    dest = video.download_video("http://films.example.org/game.mp4", tmp_path / "game.mp4", public_only=True)
    assert dest.read_bytes() == b"film"
    assert fake_internet.connections == [("93.184.216.34", 80), ("8.8.4.4", 80)]


def test_public_only_https_connections_are_pinned_too():
    connection = video._PublicHTTPSConnection("films.example.org", 443, timeout=5)
    assert connection._create_connection is video._connect_public and connection.host == "films.example.org"


def test_the_modal_download_is_unchanged(monkeypatch, tmp_path):
    """Modal downloads in its own container: no address check (and urlopen as before)."""
    _serve(monkeypatch, _FakeResponse(b"film"))
    assert video.download_video("http://10.0.0.5/f.mp4", tmp_path / "f.mp4").read_bytes() == b"film"


def test_the_local_processor_refuses_a_link_into_the_servers_network(monkeypatch, no_network, settings):
    def must_not_run(*args, **kwargs):
        raise AssertionError("the pipeline ran on a refused link")

    monkeypatch.setattr(runner, "run_pipeline", must_not_run)
    processor = LocalProcessor(settings)
    link = VideoSource(kind="url", filename="film.mp4", url="http://127.0.0.1:6379/film.mp4")  # the server's Redis
    status = _wait_until_finished(processor, processor.submit(job_id="j_ssrf", video=link, options={}))
    assert status.state == "failed" and status.error.code == ErrorCode.VIDEO_DOWNLOAD_FAILED
    assert "Upload the film file instead" in status.error.message
    assert no_network == [link.url]  # refused at once, not retried


def test_the_local_processor_downloads_with_public_only(monkeypatch, settings):
    calls: list[dict] = []

    def download(url, dest, **kwargs):
        calls.append(kwargs)
        raise PipelineError(errors.VIDEO_DOWNLOAD_FAILED, "stop here")

    monkeypatch.setattr(video, "download_video", download)
    processor = LocalProcessor(settings)
    link = VideoSource(kind="url", filename="film.mp4", url="https://films.example.org/film.mp4")
    status = _wait_until_finished(processor, processor.submit(job_id="j_url", video=link, options={}))
    assert status.error.code == ErrorCode.VIDEO_DOWNLOAD_FAILED
    assert calls and calls[0].get("public_only") is True


# ---------------------------------------------------------------------------
# 6. An OHV checkout older than the pinned commit
# ---------------------------------------------------------------------------


def _fake_git(monkeypatch, *, has_commit: bool) -> list[tuple[list[str], dict]]:
    calls: list[tuple[list[str], dict]] = []

    def run(cmd, **kwargs):
        calls.append((cmd, kwargs))
        missing = "cat-file" in cmd and not has_commit
        return subprocess.CompletedProcess(cmd, 128 if missing else 0, b"", b"")

    monkeypatch.setattr(ohv.subprocess, "run", run)
    monkeypatch.setattr(ohv, "WEIGHTS", ())  # no checkpoint downloads
    return calls


def test_install_fetches_a_pinned_commit_that_an_old_clone_lacks(monkeypatch, tmp_path):
    (tmp_path / "ohv" / ".git").mkdir(parents=True)  # cloned before OHV_COMMIT was pinned
    calls = _fake_git(monkeypatch, has_commit=False)
    ohv.install_openhoopvision(tmp_path / "ohv")
    root = str(tmp_path / "ohv")
    assert [cmd for cmd, _ in calls] == [
        ["git", "-C", root, "cat-file", "-e", f"{ohv.OHV_COMMIT}^{{commit}}"],
        ["git", "-C", root, "fetch", "--quiet", "origin"],
        ["git", "-C", root, "checkout", "--detach", ohv.OHV_COMMIT],
    ]
    assert all(kwargs["env"]["GIT_LFS_SKIP_SMUDGE"] == "1" for _, kwargs in calls)
    assert calls[1][1]["check"] is True


def test_install_does_not_fetch_when_the_commit_is_already_there(monkeypatch, tmp_path):
    (tmp_path / "ohv" / ".git").mkdir(parents=True)
    calls = _fake_git(monkeypatch, has_commit=True)
    ohv.install_openhoopvision(tmp_path / "ohv")
    assert [cmd[3] for cmd, _ in calls] == ["cat-file", "checkout"]


# ---------------------------------------------------------------------------
# 7. Cover art, VIDEO_TOO_LONG, relative custom weights
# ---------------------------------------------------------------------------


def test_ffmpeg_never_picks_a_cover_art_stream(monkeypatch, tmp_path):
    plan = video.plan_analysis(_probe(), filename="a.mp4", analysis_fps=15, max_side=1280)
    transcode = video.build_transcode_command("in.mp4", "out.mp4", plan)
    assert transcode[transcode.index("-map") + 1] == "0:V:0"  # V: video streams that are not attached pictures
    commands: list[list[str]] = []
    monkeypatch.setattr(video.subprocess, "run", lambda cmd, **_: commands.append(cmd) or SimpleNamespace(returncode=0))
    video.check_decodable(tmp_path / "film.mp4")
    assert commands[0][commands[0].index("-map") + 1] == "0:V:0"


def _ffprobe_with_cover_art_first() -> dict:
    cover = {
        "index": 0, "codec_type": "video", "codec_name": "mjpeg", "width": 600, "height": 600,
        "avg_frame_rate": "0/0", "r_frame_rate": "90000/1", "disposition": {"attached_pic": 1},
    }  # fmt: skip
    film = {
        "index": 1, "codec_type": "video", "codec_name": "h264", "width": 1280, "height": 720,
        "avg_frame_rate": "15/1", "r_frame_rate": "15/1", "nb_frames": "900", "disposition": {"attached_pic": 0},
    }  # fmt: skip
    return {"streams": [cover, film], "format": {"duration": "60.0"}}


def test_a_film_with_cover_art_first_is_always_copied_for_ohv():
    """OHV opens the file with OpenCV, which reads the first video stream: the cover picture."""
    probe = video.parse_ffprobe_json(_ffprobe_with_cover_art_first(), path="phone.mp4")
    assert (probe.codec, probe.width, probe.fps) == ("h264", 1280, 15.0) and probe.cover_art_first
    plan = video.plan_analysis(probe, filename="phone.mp4", analysis_fps=15, max_side=1280)
    assert plan.transcode and plan.step == 1  # otherwise this film would be read as it is
    ready = video.plan_analysis(_probe(), filename="a.mp4", analysis_fps=15, max_side=1280)
    assert not ready.transcode


def _probe(**overrides) -> VideoProbe:
    values = dict(path="game.mp4", fps=15.0, fps_rational="15/1", width=1280, height=720, duration_s=60.0,
                  frame_count=900, codec="h264")  # fmt: skip
    values.update(overrides)
    return VideoProbe(**values)


@pytest.mark.parametrize(
    ("duration_s", "limit_s", "text"),
    [
        (9024.0, 9000.0, "The film is 150.4 minutes long; the limit is 150.0 minutes."),
        (9601.0, 9000.0, "The film is 160 minutes long; the limit is 150 minutes."),
        (9001.2, 9000.0, "The film is 150.02 minutes long; the limit is 150.00 minutes."),
    ],
)
def test_too_long_message_tells_the_two_durations_apart(duration_s, limit_s, text):
    with pytest.raises(PipelineError) as info:
        video.validate_probe(_probe(duration_s=duration_s), max_duration_s=limit_s)
    assert info.value.code == errors.VIDEO_TOO_LONG and info.value.message == text


def test_relative_custom_weights_are_made_absolute_for_the_check_and_for_ohv(monkeypatch, tmp_path):
    """OHV runs inside its checkout and would resolve "custom/det.pth" from there."""
    work = tmp_path / "server"
    (work / "custom").mkdir(parents=True)
    (work / "custom" / "det.pth").write_bytes(b"w" * 2048)
    monkeypatch.chdir(work)
    fake = _FakeOhv((0, "", 10))
    monkeypatch.setattr(ohv.subprocess, "Popen", fake)
    ohv.run_ohv(
        tmp_path / "in.mp4", tmp_path / "work", analysis_fps=15.0, expected_frames=10, court=ohv.CourtSpec(),
        render=False, home=_fake_ohv_home(tmp_path), poll_interval_s=0.0,
        weight_overrides={"rf-detr-basketball.pth": "custom/det.pth"},
    )  # fmt: skip
    cmd = fake.commands[0]
    model = cmd[cmd.index("--model") + 1]
    assert os.path.isabs(model) and Path(model) == work / "custom" / "det.pth"
    assert all(os.path.isabs(cmd[cmd.index(w.flag) + 1]) for w in ohv.WEIGHTS)
