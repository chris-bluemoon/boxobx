"""
Boxbox Weather Radar Reader

Reads GT7's Weather Radar -- a page of the central multi-function
display ("Weather Radar", cycled with the arrows), set to its widest
100 km zoom -- by pixel colour, like water_gauge_reader.py.

Measured against real 1080p captures (test_fixtures/weather_radar_*.png,
Nurburgring):
  - The map is north-up and doesn't turn with the car; the circuit is at
    the centre crosshair (x=957.5, y=951.5).
  - The 100 km scale bar is 91 px long: 1.10 km per pixel.
  - Rain shows as a translucent teal zone with cells in it, coloured by a
    seven-step legend (light cyan .. magenta) drawn at x=828-833,
    y=909-992. The panel is see-through: grass, scenery and the car
    behind it tint everything, so rain is picked out as "bluer than it is
    red" -- true of the teal zone and the blue cells over any background,
    and not of grass, brown scenery or the neutral grey dry area. (The
    green/yellow cells are too like grass to grade reliably; the reader
    reports where rain is, not exact intensity.)
  - GT7 runs the radar time-lapsed: the rain drifts visibly within
    seconds (about 0.7 px/s in the first capture), and at a weather slot
    change it fades out (or in) where it is rather than drifting.

What it reports, for Boxington's early warnings (the water gauge still
sets the timing of a stop):
  - overTrack / coverageAtTrackPercent: rain over the circuit now.
  - nearestRainKm: how far the nearest rain is (0 if over the track).
  - arrivalSeconds: when that rain reaches the circuit, from how fast the
    distance to it has been shrinking over the last half minute (steadier
    than projecting the drift: the band changes shape as it moves, so the
    nearest point of it jumps about).
  - driftKmPerMin: how fast the rain pattern is moving.
  - trend: rain near the circuit building, fading or steady.
"""
from __future__ import annotations

from collections import deque

import cv2
import numpy as np

REFERENCE_WIDTH = 1920
REFERENCE_HEIGHT = 1080

# The map area (inside the panel: right of the legend, left of the zoom
# slider, above the scale bar).
MAP_X_MIN, MAP_X_MAX = 845, 1080
MAP_Y_MIN, MAP_Y_MAX = 864, 1028
CENTRE_X, CENTRE_Y = 957.5, 951.5
KM_PER_PX = 100 / 91

# Legend bands, heaviest first: (BGR, centre row) at x=829-832.
LEGEND_X_MIN, LEGEND_X_MAX = 829, 833
LEGEND = [
    ((156, 33, 174), 914),   # magenta
    ((170, 88, 255), 926),   # pink
    ((88, 212, 243), 938),   # yellow
    ((112, 165, 102), 950),  # green
    ((186, 83, 89), 962),    # indigo
    ((182, 161, 104), 974),  # steel blue
    ((199, 204, 149), 986),  # light cyan
]
LEGEND_MAX_DISTANCE = 60

# A rain pixel is at least this much bluer than red...
RAIN_MIN_BLUE_OVER_RED = 10
# ...and not much less blue than green (the teal is blue ~ green).
RAIN_MAX_GREEN_OVER_BLUE = 10

# Within this radius of the centre counts as over the circuit (~5.5 km:
# a circuit is a few km across).
TRACK_RADIUS_PX = 5
OVER_TRACK_COVERAGE_PERCENT = 40

# "Near the circuit", for the building/fading trend (~45 km).
NEAR_RADIUS_PX = 40

# Drift is measured against the reading at least this long ago...
MOTION_BASELINE_S = 10
# ...with enough rain on both maps and a confident match.
MOTION_MIN_RAIN_FRACTION = 0.02
MOTION_MIN_RESPONSE = 0.15
# Arrival: the nearest-rain distance fitted over this window, with at
# least this many readings; closing slower than this isn't "coming".
ARRIVAL_WINDOW_S = 30
ARRIVAL_MIN_READINGS = 4
MIN_CLOSING_PX_PER_S = 0.05

# Rain near the circuit up or down this much (percentage points) over
# the baseline is building/fading.
TREND_POINTS = 10
HISTORY_S = 60


def _scale_x(x: float, width: int) -> int:
    return int(round(x * width / REFERENCE_WIDTH))


def _scale_y(y: float, height: int) -> int:
    return int(round(y * height / REFERENCE_HEIGHT))


def _to_reference(frame_bgr: np.ndarray) -> np.ndarray:
    h, w = frame_bgr.shape[:2]
    if (w, h) == (REFERENCE_WIDTH, REFERENCE_HEIGHT):
        return frame_bgr
    return cv2.resize(frame_bgr, (REFERENCE_WIDTH, REFERENCE_HEIGHT), interpolation=cv2.INTER_AREA)


def radar_visible(frame_bgr: np.ndarray) -> bool:
    """True if the Weather Radar page is on screen (its legend is)."""
    f = _to_reference(frame_bgr)
    matched = 0
    for bgr, y in LEGEND:
        sample = f[y - 2:y + 3, LEGEND_X_MIN:LEGEND_X_MAX].reshape(-1, 3).astype(np.float32).mean(axis=0)
        if np.linalg.norm(sample - np.array(bgr, dtype=np.float32)) <= LEGEND_MAX_DISTANCE:
            matched += 1
    return matched >= 6


def rain_mask(frame_bgr: np.ndarray) -> np.ndarray:
    """Rain on the map (1.0) vs not (0.0), map-area sized, specks removed."""
    f = _to_reference(frame_bgr)
    p = f[MAP_Y_MIN:MAP_Y_MAX, MAP_X_MIN:MAP_X_MAX].astype(np.int16)
    b, g, r = p[:, :, 0], p[:, :, 1], p[:, :, 2]
    mask = ((b - r >= RAIN_MIN_BLUE_OVER_RED) & (g - b <= RAIN_MAX_GREEN_OVER_BLUE)).astype(np.uint8)
    mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, np.ones((3, 3), np.uint8))
    return mask.astype(np.float32)


_CX = CENTRE_X - MAP_X_MIN
_CY = CENTRE_Y - MAP_Y_MIN


def _disc(shape: tuple[int, int], radius: float) -> np.ndarray:
    ys, xs = np.mgrid[0:shape[0], 0:shape[1]]
    return (xs - _CX) ** 2 + (ys - _CY) ** 2 <= radius ** 2


def _nearest_rain(mask: np.ndarray) -> tuple[float, float, float] | None:
    """(distance px, dx, dy) from the centre to the nearest rain pixel."""
    ys, xs = np.nonzero(mask)
    if len(xs) == 0:
        return None
    dx, dy = xs - _CX, ys - _CY
    d2 = dx * dx + dy * dy
    i = int(np.argmin(d2))
    return float(np.sqrt(d2[i])), float(dx[i]), float(dy[i])


class RadarTracker:
    """Reads the radar each frame and keeps a minute of history to tell
    which way the rain is drifting and whether it's building or fading."""

    def __init__(self):
        self._history: deque[tuple[float, np.ndarray, float]] = deque()  # (t, mask, near coverage)
        self._distances: deque[tuple[float, float]] = deque()  # (t, nearest rain px)

    def reset(self) -> None:
        self._history.clear()
        self._distances.clear()

    def update(self, frame_bgr: np.ndarray, timestamp: float) -> dict | None:
        if not radar_visible(frame_bgr):
            return None
        mask = rain_mask(frame_bgr)
        track = _disc(mask.shape, TRACK_RADIUS_PX)
        near = _disc(mask.shape, NEAR_RADIUS_PX)
        at_track = float(mask[track].mean() * 100)
        near_cov = float(mask[near].mean() * 100)
        over = at_track >= OVER_TRACK_COVERAGE_PERCENT

        self._history.append((timestamp, mask, near_cov))
        while self._history and timestamp - self._history[0][0] > HISTORY_S:
            self._history.popleft()

        nearest = _nearest_rain(mask)
        velocity = self._velocity(timestamp, mask)
        if over or nearest is None:
            self._distances.clear()
        else:
            self._distances.append((timestamp, nearest[0]))
        while self._distances and timestamp - self._distances[0][0] > ARRIVAL_WINDOW_S:
            self._distances.popleft()
        arrival = None if over or nearest is None else self._arrival(nearest[0])

        return {
            "overTrack": over,
            "coverageAtTrackPercent": round(at_track, 1),
            "coverageNearPercent": round(near_cov, 1),
            "nearestRainKm": 0.0 if over else (None if nearest is None else round(nearest[0] * KM_PER_PX, 1)),
            "arrivalSeconds": arrival,
            "driftKmPerMin": None if velocity is None
            else round(float(np.hypot(*velocity)) * KM_PER_PX * 60, 1),
            "trend": self._trend(timestamp),
        }

    def _baseline(self, timestamp: float):
        """The latest reading at least MOTION_BASELINE_S old."""
        for t, mask, cov in reversed(self._history):
            if timestamp - t >= MOTION_BASELINE_S:
                return t, mask, cov
        return None

    def _velocity(self, timestamp: float, mask: np.ndarray) -> tuple[float, float] | None:
        """Rain drift, px/s (x east, y south), or None if not measurable."""
        base = self._baseline(timestamp)
        if base is None:
            return None
        t0, mask0, _ = base
        if mask.mean() < MOTION_MIN_RAIN_FRACTION or mask0.mean() < MOTION_MIN_RAIN_FRACTION:
            return None
        (dx, dy), response = cv2.phaseCorrelate(mask0, mask)
        if response < MOTION_MIN_RESPONSE:
            return None
        dt = timestamp - t0
        return dx / dt, dy / dt

    def _arrival(self, distance_px: float) -> float | None:
        """Seconds until the nearest rain reaches the circuit, if it's been
        closing steadily."""
        if len(self._distances) < ARRIVAL_MIN_READINGS:
            return None
        ts = np.array([t for t, _ in self._distances])
        ds = np.array([d for _, d in self._distances])
        if ts[-1] - ts[0] < ARRIVAL_WINDOW_S / 2:
            return None
        slope = float(np.polyfit(ts, ds, 1)[0])  # px/s, negative = closing
        if -slope < MIN_CLOSING_PX_PER_S:
            return None
        return round(max(0.0, distance_px - TRACK_RADIUS_PX) / -slope, 1)

    def _trend(self, timestamp: float) -> str | None:
        """Rain near the circuit over the last half minute or so."""
        base = self._baseline(timestamp)
        if base is None:
            return None
        recent = [cov for t, _, cov in self._history if timestamp - t <= 5]
        then = base[2]
        now = sum(recent) / len(recent)
        if now - then >= TREND_POINTS:
            return "building"
        if then - now >= TREND_POINTS or (then > 1 and now <= then * 0.6):
            return "fading"
        return "steady"
