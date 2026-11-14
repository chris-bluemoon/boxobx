"""
Boxbox mini-map traffic tracker.

Reads GT7's top-right course map from the same capture frames the
leaderboard relay already grabs, and reports where EVERY car is around
the lap relative to the driver -- including the cars the on-screen
leaderboard doesn't show.

What the map actually looks like (confirmed against real captures): a
thick white line for the circuit, opponents as light-blue arrowheads
sitting ON that line, the driver as a red arrowhead, all drawn straight
over the game scene (no backing panel -- sky, trees and clouds show
through). Opponents are almost the same blue as the sky, so they can't
be found by colour alone. Instead:

1. TrackOutline learns the circuit's shape over the first samples of a
   session: a pixel is "track" if it was white in enough of those
   frames (cars move and the sky changes, the line doesn't). No
   hand-traced outline is needed per circuit.
2. Each frame, a car is wherever a known-track pixel is currently BLUE
   (an arrowhead covering the line). Cars bunched together merge into
   one blob; its area gives an estimated car count.
3. Each blob is placed along the lap (0-1000, see TrackOutline.project),
   and turned into seconds behind the driver using the driver's own
   recent trajectory: we passed every point of the track at a known
   time, so a car sitting at a point we passed 3.2s ago is 3.2s behind.

Deliberately NOT attempted: telling which arrow is which driver (they're
identical and constantly merge). For traffic around a pit stop, where
the cars are matters, not who they are.

Known limitation: a circuit whose map crosses over itself (figure-of-8,
e.g. Suzuka) doesn't form a single loop and isn't supported yet --
TrackOutline reports not ready rather than guessing.
"""
from __future__ import annotations

from bisect import bisect_left
from dataclasses import dataclass, field

import cv2
import numpy as np

# Lap progress is normalised to 0..LAP_PROGRESS_MAX regardless of the
# circuit's real length.
LAP_PROGRESS_MAX = 1000.0

# Below this pace (lap progress per second; a 90 s lap averages ~11) the
# driver counts as stopped when timing a stretch of the current lap.
MIN_MOVING_PROGRESS_PER_SECOND = 2.0

# Generous top-right search box (1080p reference coordinates) for the
# course map. Different circuits draw differently-shaped maps, so this
# is wider than any one map; it stops above GT7's wind indicator
# ("3.3 m/s", y~265-295), whose white text would otherwise read as track.
REFERENCE_WIDTH = 1920
REFERENCE_HEIGHT = 1080
MINIMAP_X_MIN = 1440
MINIMAP_X_MAX = 1910
MINIMAP_Y_MIN = 8
MINIMAP_Y_MAX = 262

# Colour classes (OpenCV HSV, H 0-180). Measured on real captures:
# track line is near-white, opponents light blue, the driver red.
WHITE_MAX_SATURATION = 60
WHITE_MIN_VALUE = 200
BLUE_HUE_RANGE = (90, 112)
BLUE_MIN_SATURATION = 60
BLUE_MIN_VALUE = 170
RED_MIN_SATURATION = 120
RED_MIN_VALUE = 120

# Outline learning: the minimum frames to learn from, and the fraction
# of them a pixel must be white in to count as track. If the loop isn't
# closed yet (e.g. the pack sat on one stretch for most of those
# frames), learning simply continues -- cars move on and uncover it --
# up to OUTLINE_MAX_LEARNING_FRAMES before starting over.
OUTLINE_LEARNING_FRAMES = 12
OUTLINE_MAX_LEARNING_FRAMES = 90
OUTLINE_MIN_WHITE_FRACTION = 0.3
# The learned loop must be at least this long (1080p pixels) to be
# believable as a circuit rather than a stray white shape.
OUTLINE_MIN_LOOP_LENGTH_PX = 250

# A blob of covered track smaller than this (1080p px) is noise; one
# arrowhead covers about SINGLE_CAR_COVERED_PX of track.
MIN_CAR_BLOB_PX = 6
SINGLE_CAR_COVERED_PX = 40
MIN_PLAYER_BLOB_PX = 15

# How far (1080p px) a blob's centre may be from the learned line and
# still be placed on it.
SNAP_RADIUS_PX = 12

# If fewer than this fraction of the learned track pixels look like
# track (white or covered by a car) for RELEARN_AFTER_BAD_FRAMES samples
# in a row, the circuit has changed (or the map is gone) -- relearn.
MIN_OUTLINE_MATCH_FRACTION = 0.5
RELEARN_AFTER_BAD_FRAMES = 8

# Driving direction is decided once the driver's marker has moved
# forward/backward consistently over this many samples.
DIRECTION_DECISION_SAMPLES = 5


def _scale(frame_width: int, frame_height: int) -> tuple[float, float]:
    return frame_width / REFERENCE_WIDTH, frame_height / REFERENCE_HEIGHT


def crop_minimap(frame_bgr: np.ndarray) -> np.ndarray:
    """The course-map search box, scaled to the frame's resolution."""
    height, width = frame_bgr.shape[:2]
    sx, sy = _scale(width, height)
    return frame_bgr[int(MINIMAP_Y_MIN * sy) : int(MINIMAP_Y_MAX * sy), int(MINIMAP_X_MIN * sx) : int(MINIMAP_X_MAX * sx)]


def _masks(map_bgr: np.ndarray):
    hsv = cv2.cvtColor(map_bgr, cv2.COLOR_BGR2HSV)
    h, s, v = hsv[..., 0], hsv[..., 1], hsv[..., 2]
    white = (s < WHITE_MAX_SATURATION) & (v > WHITE_MIN_VALUE)
    blue = (h >= BLUE_HUE_RANGE[0]) & (h <= BLUE_HUE_RANGE[1]) & (s > BLUE_MIN_SATURATION) & (v > BLUE_MIN_VALUE)
    red = ((h <= 10) | (h >= 170)) & (s > RED_MIN_SATURATION) & (v > RED_MIN_VALUE)
    return white, blue, red


def circular_delta(previous_s: float, current_s: float) -> float:
    """Signed shortest move from previous_s to current_s around the lap,
    in (-LAP_PROGRESS_MAX/2, LAP_PROGRESS_MAX/2]."""
    d = (current_s - previous_s) % LAP_PROGRESS_MAX
    return d - LAP_PROGRESS_MAX if d > LAP_PROGRESS_MAX / 2 else d


class TrackOutline:
    """The circuit's shape on the map, learned from the white line."""

    def __init__(self, area_scale: float = 1.0):
        self._area_scale = area_scale
        self._votes: np.ndarray | None = None
        self._frames = 0
        self.mask: np.ndarray | None = None  # learned track pixels (uint8 0/1)
        self._points: np.ndarray | None = None  # ordered loop, Nx2 (x, y)
        self._cumulative: np.ndarray | None = None
        self._length = 0.0
        self.ready = False

    def learn(self, white: np.ndarray) -> None:
        if self.ready:
            return
        if self._votes is None or self._votes.shape != white.shape:
            self._votes = np.zeros(white.shape, np.uint16)
            self._frames = 0
        self._votes += white.astype(np.uint16)
        self._frames += 1
        if self._frames >= OUTLINE_LEARNING_FRAMES:
            self._build()

    def _build(self) -> None:
        track = (self._votes >= max(1, OUTLINE_MIN_WHITE_FRACTION * self._frames)).astype(np.uint8)
        # Bridge the small gaps GT7 draws in the line (sector ticks) and
        # any spot a car happened to sit on in most learning frames.
        track = cv2.morphologyEx(track, cv2.MORPH_CLOSE, np.ones((7, 7), np.uint8))
        count, labels, stats, _ = cv2.connectedComponentsWithStats(track)
        if count < 2:
            return self._not_closed_yet()
        largest = 1 + int(np.argmax(stats[1:, cv2.CC_STAT_AREA]))
        track = (labels == largest).astype(np.uint8)

        # A closed circuit is a band with a hole in the middle; the
        # hole's boundary is an ordered loop running along the line.
        contours, hierarchy = cv2.findContours(track, cv2.RETR_CCOMP, cv2.CHAIN_APPROX_NONE)
        holes = [c for c, h in zip(contours, hierarchy[0]) if h[3] != -1] if hierarchy is not None else []
        # Ignore pinholes left by compression/noise inside the line.
        holes = [h for h in holes if cv2.contourArea(h) >= 200 * self._area_scale]
        if len(holes) != 1:
            # No hole: the loop isn't closed (yet). Several: a circuit
            # that crosses itself, which isn't supported.
            return self._not_closed_yet()
        loop = holes[0][:, 0, :].astype(np.float64)
        deltas = np.diff(np.vstack([loop, loop[:1]]), axis=0)
        cumulative = np.concatenate([[0.0], np.cumsum(np.hypot(deltas[:, 0], deltas[:, 1]))])
        if cumulative[-1] < OUTLINE_MIN_LOOP_LENGTH_PX * np.sqrt(self._area_scale):
            return self._not_closed_yet()

        self.mask = track
        self._points = loop
        self._cumulative = cumulative
        self._length = float(cumulative[-1])
        self.ready = True

    def _not_closed_yet(self) -> None:
        if self._frames >= OUTLINE_MAX_LEARNING_FRAMES:
            self._votes = None
            self._frames = 0

    def reverse(self) -> None:
        """Flips the lap direction (the loop's traced order may be the
        opposite of the way cars drive)."""
        if self._points is None:
            return
        self._points = self._points[::-1].copy()
        deltas = np.diff(np.vstack([self._points, self._points[:1]]), axis=0)
        self._cumulative = np.concatenate([[0.0], np.cumsum(np.hypot(deltas[:, 0], deltas[:, 1]))])

    def project(self, x: float, y: float) -> float | None:
        """Lap progress (0..1000) of the nearest point on the loop, or
        None if (x, y) is too far from the line to be on it."""
        if self._points is None:
            return None
        d2 = (self._points[:, 0] - x) ** 2 + (self._points[:, 1] - y) ** 2
        index = int(np.argmin(d2))
        if d2[index] > (SNAP_RADIUS_PX**2) * self._area_scale:
            return None
        return self._cumulative[index] / self._length * LAP_PROGRESS_MAX

    def match_fraction(self, white: np.ndarray, blue: np.ndarray, red: np.ndarray) -> float:
        """How much of the learned track currently looks like track."""
        if self.mask is None:
            return 0.0
        on_track = self.mask > 0
        return float(((white | blue | red) & on_track).sum()) / max(1, int(on_track.sum()))


@dataclass
class TrafficCar:
    """One blob of opponent arrowhead(s) on the line."""

    lap_progress: float
    count: int
    # How long ago the driver passed this point, 0..lap time (i.e. how
    # far behind us around the lap, in seconds). None until a full lap
    # of the driver's own trajectory has been recorded.
    seconds_behind: float | None = None
    # How long this car takes to reach the driver's current point at the
    # driver's own pace, 0..lap time. Unlike seconds_behind it doesn't
    # grow while the driver is stopped (after a spin or an off), so it's
    # a real arrival time -- what the "wait... go" rejoin call needs.
    seconds_to_reach: float | None = None


@dataclass
class TrafficSnapshot:
    track_ready: bool
    player_lap_progress: float | None
    lap_seconds: float | None
    cars: list[TrafficCar] = field(default_factory=list)

    def to_payload(self) -> dict:
        return {
            "trackReady": self.track_ready,
            "playerLapProgress": None if self.player_lap_progress is None else round(self.player_lap_progress, 1),
            "lapSeconds": None if self.lap_seconds is None else round(self.lap_seconds, 2),
            "cars": [
                {
                    "lapProgress": round(c.lap_progress, 1),
                    "count": c.count,
                    "secondsBehind": None if c.seconds_behind is None else round(c.seconds_behind, 2),
                    "secondsToReach": None if c.seconds_to_reach is None else round(c.seconds_to_reach, 2),
                }
                for c in self.cars
            ],
        }


class TrafficTracker:
    """Per-session state: the learned outline, the driving direction,
    and the driver's own trajectory used to turn distance into time."""

    def __init__(self):
        self._outline: TrackOutline | None = None
        self._bad_frames = 0
        self._direction_votes: list[float] = []
        self._direction_known = False
        # Driver trajectory: (timestamp, unwrapped lap progress), oldest first.
        self._trail_t: list[float] = []
        self._trail_s: list[float] = []
        self._last_s: float | None = None

    def reset(self) -> None:
        self.__init__()

    def update(self, frame_bgr: np.ndarray, timestamp: float) -> TrafficSnapshot:
        map_bgr = crop_minimap(frame_bgr)
        sx, sy = _scale(frame_bgr.shape[1], frame_bgr.shape[0])
        area_scale = sx * sy
        white, blue, red = _masks(map_bgr)

        if self._outline is None:
            self._outline = TrackOutline(area_scale)
        outline = self._outline
        if not outline.ready:
            outline.learn(white)
            return TrafficSnapshot(track_ready=False, player_lap_progress=None, lap_seconds=None)

        if outline.match_fraction(white, blue, red) < MIN_OUTLINE_MATCH_FRACTION:
            self._bad_frames += 1
            if self._bad_frames >= RELEARN_AFTER_BAD_FRAMES:
                self.reset()
            return TrafficSnapshot(track_ready=False, player_lap_progress=None, lap_seconds=None)
        self._bad_frames = 0

        player_s = self._locate_player(red, outline)
        if player_s is not None:
            self._record_player(player_s, timestamp)

        cars = self._locate_cars(blue, outline, area_scale)
        if player_s is not None and self._direction_known:
            for car in cars:
                car.seconds_behind = self._seconds_behind(player_s, car.lap_progress)
                car.seconds_to_reach = self._seconds_to_reach(player_s, car.lap_progress)

        return TrafficSnapshot(
            track_ready=True,
            player_lap_progress=player_s if self._direction_known else None,
            lap_seconds=self._lap_seconds(),
            cars=cars if self._direction_known else [],
        )

    # --- detection -------------------------------------------------------

    @staticmethod
    def _locate_player(red: np.ndarray, outline: TrackOutline) -> float | None:
        count, _labels, stats, centroids = cv2.connectedComponentsWithStats(red.astype(np.uint8))
        best = None
        for i in range(1, count):
            area = stats[i, cv2.CC_STAT_AREA]
            if area >= MIN_PLAYER_BLOB_PX and (best is None or area > stats[best, cv2.CC_STAT_AREA]):
                best = i
        if best is None:
            return None
        return outline.project(*centroids[best])

    @staticmethod
    def _locate_cars(blue: np.ndarray, outline: TrackOutline, area_scale: float) -> list[TrafficCar]:
        covered = (blue & (outline.mask > 0)).astype(np.uint8)
        covered = cv2.morphologyEx(covered, cv2.MORPH_CLOSE, np.ones((3, 3), np.uint8))
        count, _labels, stats, centroids = cv2.connectedComponentsWithStats(covered)
        cars = []
        for i in range(1, count):
            area = stats[i, cv2.CC_STAT_AREA] / area_scale
            if area < MIN_CAR_BLOB_PX:
                continue
            s = outline.project(*centroids[i])
            if s is None:
                continue
            cars.append(TrafficCar(lap_progress=s, count=max(1, round(area / SINGLE_CAR_COVERED_PX))))
        cars.sort(key=lambda c: c.lap_progress)
        return cars

    # --- driver trajectory -----------------------------------------------

    def _record_player(self, s: float, timestamp: float) -> None:
        if self._last_s is None:
            self._last_s = s
            return
        delta = circular_delta(self._last_s, s)
        self._last_s = s

        if not self._direction_known:
            if abs(delta) > 0.5:
                self._direction_votes.append(delta)
            if len(self._direction_votes) >= DIRECTION_DECISION_SAMPLES:
                forward = sum(1 for d in self._direction_votes if d > 0)
                if forward < len(self._direction_votes) / 2:
                    self._outline.reverse()
                    self._last_s = (LAP_PROGRESS_MAX - s) % LAP_PROGRESS_MAX
                self._direction_known = True
            return

        if delta < 0:
            # Jitter (or a brief misread): never move the trail backwards.
            return
        unwrapped = (self._trail_s[-1] if self._trail_s else self._last_s) + delta
        self._trail_t.append(timestamp)
        self._trail_s.append(unwrapped)
        # Keep a little over two laps of history.
        while self._trail_s and self._trail_s[-1] - self._trail_s[0] > 2.2 * LAP_PROGRESS_MAX:
            self._trail_t.pop(0)
            self._trail_s.pop(0)

    def _time_at(self, unwrapped_s: float) -> float | None:
        """When the driver was at unwrapped_s (linear interpolation), or
        None if outside the recorded trail."""
        if not self._trail_s or unwrapped_s < self._trail_s[0] or unwrapped_s > self._trail_s[-1]:
            return None
        i = bisect_left(self._trail_s, unwrapped_s)
        if self._trail_s[i] == unwrapped_s or i == 0:
            return self._trail_t[i]
        s0, s1 = self._trail_s[i - 1], self._trail_s[i]
        t0, t1 = self._trail_t[i - 1], self._trail_t[i]
        return t0 + (t1 - t0) * (unwrapped_s - s0) / (s1 - s0)

    def _seconds_behind(self, player_s: float, car_s: float) -> float | None:
        """How long ago the driver passed the car's current point."""
        if not self._trail_s:
            return None
        distance_behind = (player_s - car_s) % LAP_PROGRESS_MAX
        now_s, now_t = self._trail_s[-1], self._trail_t[-1]
        passed_at = self._time_at(now_s - distance_behind)
        return None if passed_at is None else now_t - passed_at

    def _seconds_to_reach(self, player_s: float, car_s: float) -> float | None:
        """How long a car at car_s takes to reach the driver's point at
        the driver's own pace: the time the driver took over that same
        stretch on the previous lap or, without a previous lap yet, on
        the current one with any time spent (nearly) stopped left out."""
        if not self._trail_s:
            return None
        distance_behind = (player_s - car_s) % LAP_PROGRESS_MAX
        now_s = self._trail_s[-1]

        lap_ago_end = self._time_at(now_s - LAP_PROGRESS_MAX)
        lap_ago_start = self._time_at(now_s - LAP_PROGRESS_MAX - distance_behind)
        if lap_ago_end is not None and lap_ago_start is not None:
            return lap_ago_end - lap_ago_start

        start_s = now_s - distance_behind
        if start_s < self._trail_s[0]:
            return None
        moving = 0.0
        for i in range(bisect_left(self._trail_s, start_s), len(self._trail_s)):
            if i == 0:
                continue
            s0, s1 = self._trail_s[i - 1], self._trail_s[i]
            dt = self._trail_t[i] - self._trail_t[i - 1]
            ds = s1 - s0
            if ds <= 0 or dt <= 0 or ds / dt < MIN_MOVING_PROGRESS_PER_SECOND:
                continue
            covered = s1 - max(s0, start_s)
            moving += dt * covered / ds
        return moving

    def _lap_seconds(self) -> float | None:
        """Duration of the driver's most recent full lap on the map."""
        if not self._trail_s:
            return None
        start = self._time_at(self._trail_s[-1] - LAP_PROGRESS_MAX)
        return None if start is None else self._trail_t[-1] - start
