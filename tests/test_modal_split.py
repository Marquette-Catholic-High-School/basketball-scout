"""A film analysed in pieces on several GPUs (modal_app/pipeline/pieces.py and split.py).

The pieces here are made from one synthetic film: six players who drift across the frame, each
piece numbering them its own way (as OpenHoopVision does), so the join has to find the same
player on both sides of a cut by his boxes in the overlap.
"""

from __future__ import annotations

import gzip
import json
from pathlib import Path
from typing import Any

import modal
import pytest

import modal_app.app as app_module
from modal_app.pipeline import adapter, ohv, pieces, render, runner, split, video
from modal_app.pipeline.errors import PipelineError
from modal_app.pipeline.pieces import PieceSpec, PieceTracks
from modal_app.pipeline.video import FrameMap, VideoProbe
from tests.test_modal_pipeline import _meta

PLAYERS = 6
DARK, LIGHT = (40, 30, 20), (230, 230, 235)


def _box(player: int, frame: int, *, moved: float = 0.0) -> list[float]:
    x = 60 + 200 * player + (frame % 300) * 0.8 + moved
    y = 300 + 12 * player
    return [x, y, x + 60, y + 170]


def _piece_records(
    spec: PieceSpec,
    total: int,
    *,
    id_base: int,
    flip: int = 0,
    late: int = 0,
    moved: float = 0.0,
    shots: tuple[tuple[int, int], ...] = (),
) -> list[dict[str, Any]]:
    """What OHV would write for ``spec``: its own ids (``id_base + player``), its own team labels
    (``flip``), ``late`` frames off at the cut, and the shots (global start frame, player) it sees."""
    end = spec.end if spec.end is not None else total
    records = []
    for local in range(end - spec.start - late):
        frame = spec.start + local + late  # the global frame this record really shows
        players = [
            {"id": id_base + p, "local_track_id": 900 + p, "box": _box(p, frame, moved=moved), "team": (p % 2) ^ flip,
             "jersey_number": str(10 + p) if frame % 30 == 0 else None}
            for p in range(PLAYERS)
        ]  # fmt: skip
        events = []
        for start, shooter in shots:
            if frame == start + 6:  # OHV reports the shot once it is over
                events.append({"event": "shot", "start_frame": start - spec.start - late + 1, "end_frame": local + 1,
                               "player_id": id_base + shooter, "team": (shooter % 2) ^ flip, "result": "made",
                               "shot_value": 2})  # fmt: skip
        records.append(
            {"frame": local + 1, "players": players, "holder_id": id_base + (frame // 100) % PLAYERS,
             "ball": {"center": [400.0, 350.0], "score": 0.8, "observed": True}, "events": events}
        )  # fmt: skip
    return records


def _write(path: Path, records: list[dict[str, Any]]) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    with gzip.open(path, "wt", encoding="utf-8") as fh:
        for record in records:
            fh.write(json.dumps(record) + "\n")
    return path


def _read(path: Path) -> list[dict[str, Any]]:
    return [json.loads(line) for line in path.read_text().splitlines()]


def _ids_by_player(records: list[dict[str, Any]], frame: int) -> dict[int, int]:
    """player -> joined id at ``frame``, recognised by the player's box."""
    record = records[frame]
    found = {}
    for player in record["players"]:
        for p in range(PLAYERS):
            if abs(player["box"][1] - _box(p, frame)[1]) < 1:
                found[p] = player["id"]
    return found


TWO = [PieceSpec(0, 0, 330, 0, 300), PieceSpec(1, 270, None, 300, None)]  # 30-frame overlap at frame 300


# ---------------------------------------------------------------------------
# plan
# ---------------------------------------------------------------------------


def test_a_game_becomes_eight_overlapping_pieces_that_share_out_every_frame():
    frames = round(75 * 60 * 15)  # the 75-minute game at 15 fps
    plan = pieces.plan_pieces(frames, 15.0)
    assert len(plan) == 8
    assert plan[0].own_start == 0 and plan[-1].own_end is None and plan[-1].end is None
    for before, after in zip(plan, plan[1:], strict=False):
        assert before.own_end == after.own_start  # every frame has exactly one owner
        assert after.start == after.own_start - 150 and before.end == before.own_end + 150  # 10 s each side
    assert max(p.own_end - p.own_start for p in plan[:-1]) == 8438  # about 9.4 minutes each


@pytest.mark.parametrize(
    ("minutes", "count"),
    [(2, 1), (9.5, 1), (10.5, 2), (32, 4), (75, 8), (150, 8)],
)
def test_one_piece_per_ten_minutes_of_film_at_most_eight(minutes, count):
    assert len(pieces.plan_pieces(round(minutes * 60 * 15), 15.0)) == count


def test_a_short_film_is_one_piece_of_the_whole_film():
    (only,) = pieces.plan_pieces(1800, 15.0)  # a live game's 2-minute part
    assert only.whole_film and only.frames is None
    assert pieces.piece_count(600, piece_s=60, max_pieces=8, overlap_s=20) == 5  # pieces of 2 minutes at least


def test_cut_command_is_frame_exact():
    cmd = pieces.build_cut_command("analysis.mp4", "piece.mp4", PieceSpec(2, 300, 750, 330, 720), "15/1")
    assert cmd[cmd.index("-ss") + 1] == "19.966667"  # half a frame before frame 300
    assert cmd[cmd.index("-frames:v") + 1] == "450" and cmd[cmd.index("-fps_mode") + 1] == "passthrough"
    assert cmd.index("-ss") < cmd.index("-i")  # an input seek: the frames before are decoded and dropped
    first = pieces.build_cut_command("analysis.mp4", "piece.mp4", PieceSpec(0, 0, 450, 0, 420), "15/1")
    assert "-ss" not in first
    last = pieces.build_cut_command("analysis.mp4", "piece.mp4", PieceSpec(3, 900, None, 930, None), "30000/2002")
    assert "-frames:v" not in last


def test_the_annotated_video_keeps_only_the_pieces_own_frames():
    cmd = render.build_render_command("in.mp4", "out.mp4", target_height=720, source_height=1080, encoder=render.X264, frames=(30, 300))
    assert cmd[cmd.index("-vf") + 1] == "select='between(n\\,30\\,329)',setpts=N/FRAME_RATE/TB,scale=-2:'min(720,ih)'"
    open_ended = render.build_render_command("in.mp4", "out.mp4", target_height=720, source_height=720, encoder=render.X264, frames=(30, None))
    assert open_ended[open_ended.index("-vf") + 1] == "select='gte(n\\,30)',setpts=N/FRAME_RATE/TB"
    whole = render.build_render_command("in.mp4", "out.mp4", target_height=720, source_height=720, encoder=render.X264)
    assert "-vf" not in whole and "-fps_mode" not in whole


def test_concat_list_quotes_paths():
    assert pieces.concat_list(["/data/a.mp4", "/data/it's.mp4"]) == "file '/data/a.mp4'\nfile '/data/it'\\''s.mp4'\n"


# ---------------------------------------------------------------------------
# join
# ---------------------------------------------------------------------------


def _join(tmp_path, specs, records_by_piece, colors=None) -> tuple[list[dict[str, Any]], pieces.JoinReport]:
    tracks = [
        PieceTracks(spec, _write(tmp_path / f"p{spec.index}.jsonl.gz", records), (colors or {}).get(spec.index, [DARK, LIGHT]))
        for spec, records in zip(specs, records_by_piece, strict=True)
    ]
    report = pieces.join_tracks(tracks, tmp_path / "joined.jsonl")
    return _read(tmp_path / "joined.jsonl"), report


def test_join_makes_one_film_with_one_id_per_player(tmp_path):
    shots = ((290, 2), (310, 3))  # one starts in piece 1's own frames, one in piece 2's; both pieces see both
    joined, report = _join(
        tmp_path, TWO,
        [_piece_records(TWO[0], 600, id_base=1, shots=shots), _piece_records(TWO[1], 600, id_base=40, flip=1, shots=shots)],
    )  # fmt: skip
    assert [r["frame"] for r in joined] == list(range(1, 601))  # every frame once, in order
    assert _ids_by_player(joined, 10) == _ids_by_player(joined, 590)  # the same id on both sides of the cut
    assert report.tracks == PLAYERS and report.cuts[0].linked == PLAYERS and report.cuts[0].shift == 0
    assert report.cuts[0].flipped and not report.warnings
    teams = {p["id"]: p["team"] for r in (joined[10], joined[590]) for p in r["players"]}
    assert len({(i, t) for r in joined for p in r["players"] for i, t in [(p["id"], p["team"])]}) == PLAYERS
    assert teams == {_ids_by_player(joined, 10)[p]: p % 2 for p in range(PLAYERS)}  # piece 2's labels swapped back
    shots_out = [e for r in joined for e in r.get("events") or ()]
    assert sorted(e["start_frame"] for e in shots_out) == [291, 311]  # each shot once, on the film's frames
    by_start = {e["start_frame"]: e for e in shots_out}
    ids = _ids_by_player(joined, 300)
    assert by_start[291]["player_id"] == ids[2] and by_start[311]["player_id"] == ids[3]
    assert by_start[311]["team"] == 1  # player 3's team, relabelled like the players
    assert {r["holder_id"] for r in joined} <= set(ids.values())
    assert all(p["local_track_id"] >= pieces.LOCAL_ID_BLOCK for p in joined[400]["players"])  # piece 2's, kept apart
    assert all(p["local_track_id"] < pieces.LOCAL_ID_BLOCK for p in joined[100]["players"])


def test_a_cut_a_frame_off_is_found_and_corrected(tmp_path):
    joined, report = _join(
        tmp_path, TWO, [_piece_records(TWO[0], 600, id_base=1), _piece_records(TWO[1], 600, id_base=40, late=1)]
    )
    assert report.cuts[0].shift == 1 and report.cuts[0].linked == PLAYERS
    frames = [r["frame"] for r in joined]
    assert frames == sorted(set(frames)) and frames[0] == 1 and frames[-1] == 600
    assert _ids_by_player(joined, 10) == _ids_by_player(joined, 598)
    assert all(abs(p["box"][0] - _box(0, r["frame"] - 1)[0]) < 1e-6 for r in joined for p in r["players"][:1])


def test_players_who_cannot_be_followed_across_a_cut_start_new_tracks_and_warn(tmp_path):
    joined, report = _join(
        tmp_path, TWO,
        [_piece_records(TWO[0], 600, id_base=1), _piece_records(TWO[1], 600, id_base=40, flip=1, moved=1000.0)],
        colors={1: [LIGHT, DARK]},
    )  # fmt: skip
    assert report.cuts[0].linked == 0 and report.tracks == 2 * PLAYERS
    assert report.cuts[0].flipped  # no linked players: the jersey colours decide
    assert [w["code"] for w in report.warnings] == ["PIECES_JOIN_WEAK"]
    assert {p["team"] for p in joined[400]["players"] if p["box"][1] == _box(0, 400)[1]} == {0}


def test_the_joined_film_reads_like_one_piece(tmp_path):
    """The adapter sees one track per player over the whole film, with his jersey reads."""
    three = [PieceSpec(0, 0, 230, 0, 200), PieceSpec(1, 170, 430, 200, 400), PieceSpec(2, 370, None, 400, None)]
    _join(tmp_path, three, [_piece_records(s, 600, id_base=1 + 50 * s.index, flip=s.index % 2) for s in three])
    adapted = adapter.adapt_ohv(tmp_path / "joined.jsonl", _meta(), FrameMap.identity(15.0))
    tracks = adapted.perception.player_tracks()
    assert len(tracks) == PLAYERS
    for track in tracks:
        frames = [o.frame for o in track.obs]
        assert frames == list(range(600))
        assert len({text for _, text, _ in track.jersey_reads}) == 1


# ---------------------------------------------------------------------------
# coordinator
# ---------------------------------------------------------------------------


class FakeCalls:
    """The GPU pieces, run in-process: each writes what OHV would have written for it."""

    def __init__(self, root: Path, total: int, *, fail: int | None = None, polls: int = 2, encoders=None) -> None:
        self.root, self.total, self.fail, self.polls = root, total, fail, polls
        self.requests: list[dict[str, Any]] = []
        self.cancelled: list[int] = []
        self.forgotten: list[str] = []
        self.checked: dict[int, int] = {}
        self.encoders = encoders or {}

    def spawn(self, request):
        assert (self.root / request["video"]).is_file()  # the analysis copy is on the volume
        self.requests.append(request)
        return request["piece"]["index"]

    def result(self, call):
        self.checked[call] = self.checked.get(call, 0) + 1
        if self.checked[call] < self.polls + call:  # later pieces take longer
            return None
        if call == self.fail:
            return {"status": "error", "error": {"code": "GPU_OOM", "message": "The GPU ran out of memory.", "detail": "oom"}}
        request = self.requests[call]
        spec = PieceSpec.from_dict(request["piece"])
        out = self.root / request["output_dir"]
        _write(out / split.TRACKS_FILE, _piece_records(spec, self.total, id_base=1 + 30 * call))
        (out / split.VIDEO_FILE).write_bytes(f"piece {call}".encode())
        return {
            "status": "ok", "index": call, "tracks_path": f"{request['output_dir']}/{split.TRACKS_FILE}",
            "video_path": f"{request['output_dir']}/{split.VIDEO_FILE}", "encoder": self.encoders.get(call, render.NVENC),
            "summary": {"team_colors_bgr": [DARK, LIGHT], "frames": 100}, "params": {"detector_batch_size": 16, "made_up": 1},
            "attempts": 1 + call, "elapsed_s": 60.0 + call, "warnings": [{"code": "OCR_SPARSE", "message": "few", "severity": "warning"}],
            "log_tail": [f"piece {call} log"], "gpu": "NVIDIA L40S",
        }  # fmt: skip

    def cancel(self, call):
        self.cancelled.append(call)

    def progress(self, key):
        return 0.5

    def forget(self, key):
        self.forgotten.append(key)


@pytest.fixture
def film(monkeypatch, tmp_path):
    """A 300-second, 15 fps 1280x720 film on the volume: analysed as it is (no analysis copy)."""
    root = tmp_path / "volume"
    path = root / "uploads" / "j_1" / "film.mp4"
    path.parent.mkdir(parents=True)
    path.write_bytes(b"film")
    probe = VideoProbe(path=str(path), fps=15.0, fps_rational="15/1", width=1280, height=720, duration_s=300.0, frame_count=4500, codec="h264")
    monkeypatch.setattr(video, "probe_video", lambda p: probe)
    monkeypatch.setattr(video, "check_decodable", lambda p: None)
    concats: list[list[str]] = []

    def fake_ffmpeg(cmd, **kwargs):  # only the join of the annotated videos runs ffmpeg here
        concats.append(cmd)
        listing = Path(cmd[cmd.index("-i") + 1]).read_text()
        parts = [Path(line[len("file '") : -1]).read_bytes() for line in listing.splitlines()]
        Path(cmd[-1]).write_bytes(b"+".join(parts))

    monkeypatch.setattr(video, "run_ffmpeg", fake_ffmpeg)
    return root, path, concats


def _analyse(root: Path, path: Path, calls: FakeCalls, *, sleeps: list[float] | None = None, **options) -> dict[str, Any]:
    out = root / "results" / "j_1"
    perceiver = split.SplitPerceiver(
        calls, job_id="j_1", root=root, output_dir=out, commit=lambda: None, reload=lambda: None,
        settings=split.SplitSettings(piece_s=150.0, max_pieces=8), sleep=(sleeps if sleeps is not None else []).append,
    )  # fmt: skip
    seen: list[tuple[str, float, str]] = []
    response = runner.run_pipeline(
        str(path), {"analysis_fps": 15, **options}, output_dir=str(out), job_id="j_1",
        progress=lambda s, p, m: seen.append((s, p, m)), perceive=perceiver,
    )  # fmt: skip
    response["_progress"] = seen
    return response


def test_a_film_is_analysed_in_pieces_and_joined(film):
    root, path, concats = film
    calls = FakeCalls(root, 4500)
    sleeps: list[float] = []
    response = _analyse(root, path, calls, sleeps=sleeps)
    assert response["status"] == "ok", response
    assert [r["piece"]["index"] for r in calls.requests] == [0, 1]
    assert calls.requests[0]["video"] == "uploads/j_1/film.mp4" and calls.requests[1]["output_dir"] == "results/j_1/pieces/1"
    assert calls.requests[1]["piece"] == {"index": 1, "start": 2100, "end": None, "own_start": 2250, "own_end": None}
    assert calls.requests[0]["fps_rational"] == "15/1" and calls.requests[0]["render"] is True
    assert sleeps and set(sleeps) == {5.0}
    assert calls.forgotten == ["j_1:piece0", "j_1:piece1"]

    out = root / "results" / "j_1"
    assert not (out / "pieces").exists()  # the pieces' files are gone once joined
    assert (out / runner.ANNOTATED_FILE).read_bytes() == b"piece 0+piece 1"
    assert concats[0][concats[0].index("-c") + 1] == "copy"
    tracking = json.loads(gzip.decompress((out / runner.TRACKING_FILE).read_bytes()))
    players = [t for t in tracking["tracks"] if t.get("role", "player") == "player"]
    assert len(players) == PLAYERS  # one track per player over the whole film
    assert tracking["pipeline"]["gpu"] == "NVIDIA L40S"
    options = tracking["pipeline"]["options"]
    assert [p["own_start_frame"] for p in options["pieces"]] == [0, 2250] and options["ohv_attempts"] == 2
    assert options["ohv_params"]["detector_batch_size"] == 16
    assert [w["code"] for w in tracking["warnings"]].count("OCR_SPARSE") <= 1
    messages = [m for s, _, m in response["_progress"] if s == "ohv"]
    assert "Starting player and ball tracking on 2 GPUs at once" in messages
    assert (out / runner.OHV_LOG_FILE).read_text().splitlines()[:2] == ["--- piece 1 of 2 ---", "piece 0 log"]


def test_pieces_from_different_encoders_are_joined_by_encoding_once_more(film):
    root, path, concats = film
    response = _analyse(root, path, FakeCalls(root, 4500, encoders={1: render.X264}))
    assert response["status"] == "ok"
    assert "copy" not in concats[0] and concats[0][concats[0].index("-c:v") + 1] == render.X264


def test_a_failed_piece_fails_the_film_and_stops_the_others(film):
    root, path, _ = film
    calls = FakeCalls(root, 4500, fail=0)
    response = _analyse(root, path, calls)
    assert response["status"] == "error"
    assert response["error"]["code"] == "GPU_OOM" and response["error"]["detail"].startswith("piece 1 of 2")
    assert calls.cancelled == [1]
    assert not (root / "results" / "j_1" / "pieces").exists()


def test_cancelling_the_film_cancels_its_pieces(film):
    root, path, _ = film
    calls = FakeCalls(root, 4500, polls=99)

    def cancelled(_seconds):
        raise modal.exception.InputCancellation("cancelled")

    perceiver = split.SplitPerceiver(
        calls, job_id="j_1", root=root, output_dir=root / "results" / "j_1", commit=lambda: None,
        reload=lambda: None, settings=split.SplitSettings(piece_s=150.0), sleep=cancelled,
    )  # fmt: skip
    with pytest.raises(modal.exception.InputCancellation):
        runner.run_pipeline(str(path), {}, output_dir=str(root / "results" / "j_1"), job_id="j_1", perceive=perceiver)
    assert sorted(calls.cancelled) == [0, 1] and calls.forgotten == ["j_1:piece0", "j_1:piece1"]


def test_a_test_run_of_the_first_frames_is_one_piece(film):
    root, path, _ = film
    calls = FakeCalls(root, 4500)
    response = _analyse(root, path, calls, max_frames=300, render_video=False)
    assert response["status"] == "ok"
    assert len(calls.requests) == 1 and calls.requests[0]["max_frames"] == 300 and calls.requests[0]["render"] is False
    assert response["annotated_video_path"] is None


def test_the_analysis_copy_must_be_on_the_volume(film, tmp_path):
    root, _, _ = film
    elsewhere = tmp_path / "elsewhere" / "film.mp4"
    elsewhere.parent.mkdir()
    elsewhere.write_bytes(b"film")
    response = _analyse(root, elsewhere, FakeCalls(root, 4500))
    assert response["status"] == "error" and "not on the Modal volume" in response["error"]["message"]


# ---------------------------------------------------------------------------
# one piece (GPU container)
# ---------------------------------------------------------------------------


@pytest.fixture
def piece_stack(monkeypatch, tmp_path):
    root = tmp_path / "volume"
    (root / "tmp" / "j_1" / "analysis").mkdir(parents=True)
    (root / "tmp" / "j_1" / "analysis" / "analysis.mp4").write_bytes(b"analysis copy")
    seen: dict[str, Any] = {"ffmpeg": [], "render": None}

    def fake_ffmpeg(cmd, **kwargs):
        seen["ffmpeg"].append(cmd)
        Path(cmd[-1]).write_bytes(b"piece")

    def fake_run_ohv(video_path, work_dir, **kwargs):
        seen["ohv"] = (Path(video_path).name, kwargs)
        work = Path(work_dir)
        work.mkdir(parents=True, exist_ok=True)
        (work / "ohv_tracks.jsonl").write_text('{"frame": 1}\n')
        (work / "ohv_annotated.mp4").write_bytes(b"overlay")
        kwargs["progress"](0.5, "half way")
        return ohv.OhvRun(
            tracks_path=work / "ohv_tracks.jsonl", events_path=work / "e.json", output_video=work / "ohv_annotated.mp4",
            params=ohv.OhvParams(), attempts=2, summary=ohv.OhvSummary(team_colors_bgr=[DARK, LIGHT]),
            warnings=[{"code": "GPU_OOM_RECOVERED", "message": "smaller batches", "severity": "info"}], log_tail=["hi"],
        )  # fmt: skip

    def fake_render(src, dst, **kwargs):
        seen["render"] = kwargs
        Path(dst).write_bytes(b"web")
        return render.NVENC

    monkeypatch.setattr(video, "run_ffmpeg", fake_ffmpeg)
    monkeypatch.setattr(ohv, "run_ohv", fake_run_ohv)
    monkeypatch.setattr(ohv, "gpu_name", lambda: "NVIDIA L40S")
    monkeypatch.setattr(render, "render_web_video", fake_render)
    return root, seen


def _piece_request(spec: PieceSpec, **extra) -> dict[str, Any]:
    return {
        "job_id": "j_1", "video": "tmp/j_1/analysis/analysis.mp4", "fps_rational": "15/1", "analysis_fps": 15.0,
        "expected_frames": 4500, "court": {"length_ft": 84.0, "width_ft": 50.0}, "render": True, "render_height": 720,
        "source_height": 720, "weights": {}, "max_frames": None, "piece": spec.to_dict(),
        "output_dir": f"results/j_1/pieces/{spec.index}", **extra,
    }  # fmt: skip


def test_a_piece_is_cut_out_analysed_and_left_on_the_volume(piece_stack):
    root, seen = piece_stack
    progress: list[tuple[float, str]] = []
    response = split.run_piece(_piece_request(PieceSpec(1, 2100, 4400, 2250, 4250)), root=root, progress=lambda f, m: progress.append((f, m)))
    assert response["status"] == "ok", response
    assert seen["ffmpeg"][0][seen["ffmpeg"][0].index("-frames:v") + 1] == "2300"
    name, kwargs = seen["ohv"]
    assert name == "piece.mp4" and kwargs["expected_frames"] == 2300 and kwargs["court"] == ohv.CourtSpec(84.0, 50.0)
    assert seen["render"]["frames"] == (150, 2000)  # its own stretch of the overlay, without the overlap
    out = root / "results" / "j_1" / "pieces" / "1"
    assert gzip.decompress((out / split.TRACKS_FILE).read_bytes()) == b'{"frame": 1}\n'
    assert response["tracks_path"] == "results/j_1/pieces/1/ohv_tracks.jsonl.gz"
    assert response["video_path"] == "results/j_1/pieces/1/annotated.mp4" and response["encoder"] == render.NVENC
    assert response["summary"]["team_colors_bgr"] == [DARK, LIGHT] and response["attempts"] == 2 and response["gpu"] == "NVIDIA L40S"
    assert progress[0] == (0.0, "Cutting this piece of the film") and progress[-1] == (1.0, "Piece done")


def test_a_one_piece_film_is_not_cut(piece_stack):
    root, seen = piece_stack
    response = split.run_piece(_piece_request(PieceSpec(0, 0, None, 0, None)), root=root)
    assert response["status"] == "ok" and not seen["ffmpeg"]
    assert seen["ohv"][0] == "analysis.mp4" and seen["ohv"][1]["expected_frames"] == 4500
    assert seen["render"]["frames"] is None


def test_a_piece_reports_its_failures(piece_stack, monkeypatch):
    root, _ = piece_stack
    missing = split.run_piece(_piece_request(PieceSpec(0, 0, None, 0, None), video="tmp/j_1/nothing.mp4"), root=root)
    assert missing["status"] == "error" and missing["error"]["code"] == "VIDEO_INVALID"

    def oom(*args, **kwargs):
        raise RuntimeError("CUDA out of memory")

    monkeypatch.setattr(ohv, "run_ohv", oom)
    failed = split.run_piece(_piece_request(PieceSpec(0, 0, None, 0, None)), root=root)
    assert failed["status"] == "error" and failed["error"]["code"] == "GPU_OOM" and failed["index"] == 0


def test_a_piece_without_its_overlay_still_counts(piece_stack, monkeypatch):
    root, _ = piece_stack

    def no_render(*args, **kwargs):
        raise PipelineError("PIPELINE_FAILED", "The annotated video could not be encoded.", detail="nvenc")

    monkeypatch.setattr(render, "render_web_video", no_render)
    response = split.run_piece(_piece_request(PieceSpec(0, 0, 400, 0, 370)), root=root)
    assert response["status"] == "ok" and response["video_path"] is None
    assert "ANNOTATED_VIDEO_FAILED" in [w["code"] for w in response["warnings"]]


# ---------------------------------------------------------------------------
# Modal app
# ---------------------------------------------------------------------------


class _Call:
    def __init__(self, outcome):
        self.outcome, self.cancelled = outcome, False

    def get(self, timeout=None):
        if isinstance(self.outcome, BaseException):
            raise self.outcome
        return self.outcome

    def cancel(self):
        self.cancelled = True


def test_modal_piece_calls_tell_running_from_finished_from_failed():
    calls = app_module.ModalPieceCalls(function=None, store={"j_1:piece0": {"fraction": 0.4}})
    assert calls.result(_Call(TimeoutError())) is None  # still running
    assert calls.result(_Call(modal.exception.ConnectionError("down"))) is None  # ask again later
    assert calls.result(_Call({"status": "ok"})) == {"status": "ok"}
    timed_out = calls.result(_Call(modal.exception.FunctionTimeoutError("6 h")))
    assert timed_out["status"] == "error" and "time limit" in timed_out["error"]["message"]
    crashed = calls.result(_Call(RuntimeError("container died")))
    assert crashed["status"] == "error" and "container died" in crashed["error"]["message"]
    assert calls.progress("j_1:piece0") == 0.4 and calls.progress("j_1:piece9") is None
    calls.forget("j_1:piece0")
    calls.forget("j_1:piece0")  # twice: no error
    assert calls.progress("j_1:piece0") is None
    assert app_module.split_progress_key({"job_id": "j_1", "piece": {"index": 3}}) == "j_1:piece3"


class _Volume:
    def __init__(self, fail: bool = False):
        self.fail, self.commits = fail, 0

    def commit(self):
        self.commits += 1
        if self.fail:
            raise RuntimeError("volume busy")

    def reload(self):
        pass


def test_a_piece_whose_results_cannot_be_saved_fails():
    assert app_module.finish_piece({"status": "ok", "index": 2}, _Volume()) == {"status": "ok", "index": 2}
    failed = app_module.finish_piece({"status": "ok", "index": 2}, _Volume(fail=True))
    assert failed["status"] == "error" and failed["index"] == 2


def test_process_video_hands_the_pieces_to_the_pipeline(monkeypatch, tmp_path):
    root = tmp_path / "volume"
    (root / "uploads" / "j_abc123").mkdir(parents=True)
    (root / "uploads" / "j_abc123" / "source.mp4").write_bytes(b"film")
    seen: dict[str, Any] = {}

    def fake_run_pipeline(video_path, options, *, output_dir, job_id, progress=None, filename=None, **extra):
        seen.update(extra)
        assert Path(extra["analysis_dir"]).is_dir()
        return {"status": "ok", "job_id": job_id, "tracking_path": "results/j_abc123/tracking.json.gz", "warnings": []}

    monkeypatch.setattr(app_module, "run_pipeline", fake_run_pipeline)
    request = {"job_id": "j_abc123", "video": {"type": "volume", "path": "uploads/j_abc123/source.mp4"}}
    volume = _Volume()
    response = app_module.handle_request(
        request, volume=volume, progress_store={}, root=root, piece_calls=FakeCalls(root, 0), split=split.SplitSettings()
    )
    assert response["status"] == "ok" and volume.commits == 1
    assert isinstance(seen["perceive"], split.SplitPerceiver)
    assert seen["analysis_dir"] == str(root / "tmp" / "j_abc123" / "analysis")
    assert not (root / "tmp" / "j_abc123" / "analysis").exists()  # the analysis copy is deleted afterwards


def test_progress_is_the_average_of_the_pieces():
    class Tracker:
        def __init__(self):
            self.updates = []

        def update(self, stage, fraction, message="", *, force=False):
            self.updates.append((stage, round(fraction, 3), message))

    perceiver = split.SplitPerceiver(
        FakeCalls(Path("."), 0), job_id="j_1", root=Path("."), output_dir=Path("out"), commit=lambda: None, reload=lambda: None
    )
    tracker = Tracker()
    specs = [PieceSpec(i, 0, None, 0, None) for i in range(4)]
    perceiver._report(specs, {0: {"status": "ok"}}, tracker)  # one done, three half way
    assert tracker.updates == [("ohv", round(0.95 * 2.5 / 4, 3), "Tracking players and the ball on 4 GPUs (1 of 4 pieces done)")]


def test_a_short_film_runs_as_one_piece_with_its_overlay(film, monkeypatch):
    root, path, concats = film
    short = VideoProbe(path=str(path), fps=15.0, fps_rational="15/1", width=1280, height=720, duration_s=100.0, frame_count=1500, codec="h264")
    monkeypatch.setattr(video, "probe_video", lambda p: short)
    calls = FakeCalls(root, 1500)
    response = _analyse(root, path, calls)
    assert response["status"] == "ok"
    assert len(calls.requests) == 1 and calls.requests[0]["piece"]["end"] is None and not concats
    assert (root / "results" / "j_1" / runner.ANNOTATED_FILE).read_bytes() == b"piece 0"
