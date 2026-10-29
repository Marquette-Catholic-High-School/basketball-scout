"""Court geometry: dimensions, homography, shot zones and calibration landmarks.

Coordinates are feet with the origin where the LEFT baseline (x=0) meets the NEAR
sideline (y=0, camera side). See ``scout.schemas`` for the full convention.

"Half-court" coordinates normalise a location to the basket being attacked:
``hx`` = feet from the attacked baseline, ``hy`` = feet from the offense's LEFT
sideline (offense facing the basket). Shot charts draw (hy, hx) with the basket at
the top.

Defaults follow NFHS (high school): 84x50 ft court (gyms vary: set ``length_ft`` in
``config/court.yaml``), 12 ft lane, free-throw line 15 ft from the backboard (19 ft from
the baseline), basket centre 5'3" from the baseline, 3-point line 19'9" from the
basket centre with straight corner segments.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, fields
from functools import lru_cache
from pathlib import Path
from typing import Literal

import numpy as np
import yaml

from scout.errors import ErrorCode, ScoutError
from scout.schemas import BBox, Point, ShotZone

BasketSide = Literal["left", "right"]


@dataclass(frozen=True)
class CourtConfig:
    length_ft: float = 84.0
    width_ft: float = 50.0
    basket_from_baseline_ft: float = 5.25
    lane_width_ft: float = 12.0
    ft_line_from_baseline_ft: float = 19.0
    three_pt_radius_ft: float = 19.75
    three_pt_corner_lateral_ft: float = 19.75
    restricted_radius_ft: float = 4.0
    ft_circle_radius_ft: float = 6.0
    center_circle_radius_ft: float = 6.0
    corner_three_max_depth_ft: float = 10.0
    rim_height_ft: float = 10.0

    @property
    def mid_x(self) -> float:
        return self.length_ft / 2

    @property
    def mid_y(self) -> float:
        return self.width_ft / 2

    @property
    def three_pt_corner_depth_ft(self) -> float:
        """Distance from the baseline at which the straight corner segment meets the arc."""
        r, lat = self.three_pt_radius_ft, self.three_pt_corner_lateral_ft
        return self.basket_from_baseline_ft + math.sqrt(max(0.0, r * r - lat * lat))

    def basket(self, side: BasketSide) -> Point:
        b = self.basket_from_baseline_ft
        return (b, self.mid_y) if side == "left" else (self.length_ft - b, self.mid_y)


_COURT_HINT = "Fix the setting in config/court.yaml (or delete the line to use the NFHS default) and re-run."


@lru_cache(maxsize=8)
def _load_cached(path: str) -> CourtConfig:
    p = Path(path)
    if not p.exists():
        return CourtConfig()
    try:
        data = yaml.safe_load(p.read_text(encoding="utf-8")) or {}
    except (OSError, yaml.YAMLError) as exc:
        raise _config_error(f"config/court.yaml could not be read: {exc}") from exc
    if not isinstance(data, dict):
        raise _config_error("config/court.yaml must be a list of 'setting: feet' lines.")
    known = {f.name for f in fields(CourtConfig)}
    values = {}
    for key, value in data.items():
        if key not in known or value is None:
            continue
        try:
            number = float(value)
        except (TypeError, ValueError):
            number = math.nan
        if isinstance(value, bool) or not math.isfinite(number) or number <= 0:
            raise _config_error(f"court.yaml: {key} should be a number of feet above 0, got {value!r}.")
        values[key] = number
    return CourtConfig(**values)


def _config_error(message: str) -> ScoutError:
    return ScoutError(ErrorCode.CONFIG_INVALID, message, hint=_COURT_HINT, retryable=False)


def load_court_config(path: Path | str | None = None) -> CourtConfig:
    """Load ``config/court.yaml`` (missing file or keys fall back to NFHS defaults).

    Raises ``ScoutError(CONFIG_INVALID)`` naming the setting when the file cannot be used."""
    if path is None:
        from scout.config import get_settings

        path = get_settings().court_config
    return _load_cached(str(path))


# ---------------------------------------------------------------------------
# Homography
# ---------------------------------------------------------------------------


def apply_homography(matrix: list[list[float]] | np.ndarray, point: Point) -> Point | None:
    """Map one point through a 3x3 homography. Returns None near the horizon (w ~ 0)."""
    h = np.asarray(matrix, dtype=float)
    x, y = float(point[0]), float(point[1])
    w = h[2, 0] * x + h[2, 1] * y + h[2, 2]
    if abs(w) < 1e-9:
        return None
    return (
        float((h[0, 0] * x + h[0, 1] * y + h[0, 2]) / w),
        float((h[1, 0] * x + h[1, 1] * y + h[1, 2]) / w),
    )


def apply_homography_many(matrix: list[list[float]] | np.ndarray, points: np.ndarray) -> np.ndarray:
    """Vectorised version for an (N, 2) array. Rows that hit the horizon become NaN."""
    h = np.asarray(matrix, dtype=float)
    pts = np.asarray(points, dtype=float).reshape(-1, 2)
    homog = np.c_[pts, np.ones(len(pts))] @ h.T
    w = homog[:, 2:3]
    with np.errstate(divide="ignore", invalid="ignore"):
        out = homog[:, :2] / w
    out[np.abs(w[:, 0]) < 1e-9] = np.nan
    return out


def invert_homography(matrix: list[list[float]]) -> list[list[float]]:
    inv = np.linalg.inv(np.asarray(matrix, dtype=float))
    inv /= inv[2, 2]
    return inv.tolist()


def compute_homography(src_points: list[Point], dst_points: list[Point]) -> tuple[list[list[float]], float]:
    """Direct linear transform (Hartley-normalised) from >=4 correspondences.

    Returns ``(matrix, mean_error)`` where the error is measured in destination units.
    Raises ``ValueError`` for too few or degenerate (e.g. collinear) points.
    """
    src = np.asarray(src_points, dtype=float).reshape(-1, 2)
    dst = np.asarray(dst_points, dtype=float).reshape(-1, 2)
    if len(src) < 4 or src.shape != dst.shape:
        raise ValueError("need at least 4 point pairs")

    def normalise(pts: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
        centre = pts.mean(axis=0)
        spread = np.sqrt(((pts - centre) ** 2).sum(axis=1)).mean()
        if spread < 1e-9:
            raise ValueError("points are all identical")
        s = math.sqrt(2) / spread
        t = np.array([[s, 0, -s * centre[0]], [0, s, -s * centre[1]], [0, 0, 1]])
        return np.c_[pts, np.ones(len(pts))] @ t.T, t

    src_n, t_src = normalise(src)
    dst_n, t_dst = normalise(dst)
    rows = []
    for (x, y, _), (u, v, _) in zip(src_n, dst_n, strict=True):
        rows.append([-x, -y, -1, 0, 0, 0, u * x, u * y, u])
        rows.append([0, 0, 0, -x, -y, -1, v * x, v * y, v])
    _, singular, vt = np.linalg.svd(np.asarray(rows))
    if singular[-2] / singular[0] < 1e-7:
        raise ValueError("points are degenerate (collinear or duplicated)")
    h = np.linalg.inv(t_dst) @ vt[-1].reshape(3, 3) @ t_src
    if not np.all(np.isfinite(h)) or abs(h[2, 2]) < 1e-12:
        raise ValueError("homography is not finite")
    h /= h[2, 2]
    if abs(np.linalg.det(h)) < 1e-12:
        raise ValueError("homography is singular")
    projected = apply_homography_many(h, src)
    if np.isnan(projected).any():
        raise ValueError("homography maps a calibration point to infinity")
    error = float(np.linalg.norm(projected - dst, axis=1).mean())
    return h.tolist(), error


def bbox_foot_point(bbox: BBox) -> Point:
    """Bottom-centre of a bounding box: where the player touches the floor."""
    x1, _, x2, y2 = bbox
    return ((x1 + x2) / 2.0, float(y2))


# ---------------------------------------------------------------------------
# Court regions
# ---------------------------------------------------------------------------


def nearest_basket(cfg: CourtConfig, xy: Point) -> BasketSide:
    return "left" if xy[0] < cfg.mid_x else "right"


def court_half(cfg: CourtConfig, xy: Point) -> BasketSide:
    return nearest_basket(cfg, xy)


def to_half_court(cfg: CourtConfig, xy: Point, basket: BasketSide | None = None) -> Point:
    """(hx, hy): feet from the attacked baseline, feet from the offense's left sideline."""
    basket = basket or nearest_basket(cfg, xy)
    x, y = xy
    if basket == "left":
        return (x, y)
    return (cfg.length_ft - x, cfg.width_ft - y)


def distance_to_basket(cfg: CourtConfig, xy: Point, basket: BasketSide | None = None) -> float:
    bx, by = cfg.basket(basket or nearest_basket(cfg, xy))
    return math.hypot(xy[0] - bx, xy[1] - by)


def is_three(cfg: CourtConfig, xy: Point, basket: BasketSide | None = None) -> bool:
    hx, hy = to_half_court(cfg, xy, basket)
    if hx > cfg.mid_x:  # beyond half court: always a three
        return True
    lateral = abs(hy - cfg.mid_y)
    if hx <= cfg.three_pt_corner_depth_ft:
        return lateral > cfg.three_pt_corner_lateral_ft
    return math.hypot(hx - cfg.basket_from_baseline_ft, hy - cfg.mid_y) > cfg.three_pt_radius_ft


def in_paint(cfg: CourtConfig, xy: Point, basket: BasketSide | None = None) -> bool:
    """In the lane. A shot location a little behind the baseline in line with the lane is a
    projection error of a shot at the rim, so it counts as paint too (not baseline mid-range)."""
    hx, hy = to_half_court(cfg, xy, basket)
    return hx <= cfg.ft_line_from_baseline_ft and abs(hy - cfg.mid_y) <= cfg.lane_width_ft / 2


def on_court(cfg: CourtConfig, xy: Point, margin_ft: float = 2.0) -> bool:
    x, y = xy
    return -margin_ft <= x <= cfg.length_ft + margin_ft and -margin_ft <= y <= cfg.width_ft + margin_ft


def classify_shot(cfg: CourtConfig, xy: Point, basket: BasketSide | None = None) -> tuple[ShotZone, str]:
    """Return (zone, subzone) for a shot taken at ``xy`` toward ``basket`` (default: nearest)."""
    basket = basket or nearest_basket(cfg, xy)
    hx, hy = to_half_court(cfg, xy, basket)
    lateral = hy - cfg.mid_y  # negative = offense's left
    side = "left" if lateral < 0 else "right"
    angle = abs(math.degrees(math.atan2(lateral, hx - cfg.basket_from_baseline_ft)))
    if in_paint(cfg, xy, basket):
        if distance_to_basket(cfg, xy, basket) <= cfg.restricted_radius_ft:
            return ShotZone.PAINT, "restricted_area"
        return ShotZone.PAINT, "paint"
    if is_three(cfg, xy, basket):
        if hx > cfg.mid_x:
            return ShotZone.THREE, "backcourt_3"
        if hx <= cfg.corner_three_max_depth_ft and abs(lateral) >= cfg.three_pt_corner_lateral_ft - 0.5:
            return ShotZone.THREE, f"{side}_corner_3"
        if angle <= 22.5:
            return ShotZone.THREE, "top_3"
        return ShotZone.THREE, f"{side}_wing_3"
    if angle >= 60:
        return ShotZone.MID, f"{side}_baseline_mid"
    if angle >= 22.5:
        return ShotZone.MID, f"{side}_wing_mid"
    return ShotZone.MID, "top_mid"


def landmarks(cfg: CourtConfig) -> dict[str, Point]:
    """Named floor points a coach can click to calibrate a fixed camera."""
    L, W, mid = cfg.length_ft, cfg.width_ft, cfg.mid_y
    half_lane = cfg.lane_width_ft / 2
    ft = cfg.ft_line_from_baseline_ft
    lat = cfg.three_pt_corner_lateral_ft
    top3 = cfg.basket_from_baseline_ft + cfg.three_pt_radius_ft
    left = {
        "baseline_near_corner": (0.0, 0.0),
        "baseline_far_corner": (0.0, W),
        "lane_baseline_near": (0.0, mid - half_lane),
        "lane_baseline_far": (0.0, mid + half_lane),
        "ft_line_near": (ft, mid - half_lane),
        "ft_line_far": (ft, mid + half_lane),
        "ft_circle_top": (ft + cfg.ft_circle_radius_ft, mid),
        "three_corner_near": (0.0, mid - lat),
        "three_corner_far": (0.0, mid + lat),
        "three_top": (top3, mid),
    }
    points: dict[str, Point] = {}
    for name, (x, y) in left.items():
        points[f"left_{name}"] = (x, y)
        # Mirroring across the half-court line keeps the near/far sidelines.
        points[f"right_{name}"] = (L - x, y)
    points.update(
        {
            "midcourt_near": (cfg.mid_x, 0.0),
            "midcourt_far": (cfg.mid_x, W),
            "center": (cfg.mid_x, mid),
            "center_circle_near": (cfg.mid_x, mid - cfg.center_circle_radius_ft),
            "center_circle_far": (cfg.mid_x, mid + cfg.center_circle_radius_ft),
        }
    )
    return points
