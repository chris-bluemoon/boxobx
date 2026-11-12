"""
Boxbox Mini-Map Car Tracker

Standalone, fully decoupled tracker for all 16 cars in a GT7 race using
the top-right full-circuit mini-map from the same PS5 HDMI capture
stream the leaderboard OCR relay (ocr_relay.py) already reads frames
from. This module does NOT import from or modify ocr_relay.py in any
way -- it has no knowledge of EasyOCR, the leaderboard crop, or any of
that module's row-parsing logic. The only coupling point is the public
method sync_with_ocr_standings(), which the caller's own main loop can
invoke with whatever {driver_name: race_position} ground truth the OCR
module already produced, entirely independently of how this module
reaches its own best-guess ordering.

Why a separate 1D spline-projection tracker is needed at all: GT7's
mini-map renders all 15 opponents as identical plain dots (no name, no
number), so there's no way to identify *who* a given dot is from the
mini-map alone -- only track its MOTION over time and periodically
re-anchor that motion against the leaderboard OCR's real driver names
(which only shows ~9 rows at once and shifts during overtakes, but
reliably carries identity). Projecting every dot onto a 1D normalized
lap-progress coordinate (rather than tracking in raw 2D x/y) is what
makes "which blob is which car" tractable at all when dots merge into
a single blob under braking/at hairpins: two cars at the same on-track
point also have the same (or very close) lap_progress_s, so their
distinguishing signal is their velocity_ds (how fast they're each
closing on that point), not their instantaneous screen position.
"""
from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

import cv2
import numpy as np
from scipy.optimize import linear_sum_assignment
from scipy.spatial import cKDTree

# Lap progress is normalized to this range regardless of the real
# track's physical length -- keeps all the kinematic/assignment math
# below independent of which circuit is loaded.
LAP_PROGRESS_MAX = 1000.0

# A detected dot snaps to the nearest spline point if it's within this
# many pixels of the track outline -- generous enough to still count a
# car that's visibly off the raw outline while it's in the pit lane
# (which mini-maps often render as a short spur off the main loop, or
# don't render at all), without being so large that two adjacent
# straights/hairpin apexes get confused for each other.
SNAP_RADIUS_PX = 15.0

# Below this measured pixel movement per frame (after projection to
# lap-progress space), a dot's velocity contribution is treated as
# noise rather than real motion -- prevents a stationary, jittering
# blob (e.g. a crashed/stopped car) from accumulating a nonzero
# velocity purely from detection pixel noise.
MIN_MEANINGFUL_DS_PER_FRAME = 0.05

# Smoothing factor for velocity_ds's exponential moving average --
# higher reacts faster to genuine acceleration/braking, lower is more
# resistant to single-frame detection noise. 0.3 is a reasonable middle
# ground matching the kind of smoothing already used elsewhere in this
# project (e.g. GapTracker's rolling-window approach for gap trends).
VELOCITY_SMOOTHING_ALPHA = 0.3

# If a predicted car and the nearest detected blob are farther apart
# than this (in lap-progress units) after projection, they're NOT
# considered a plausible match at all for the Hungarian assignment --
# avoids ever assigning a car's identity to a wildly distant blob just
# because fewer blobs than cars were detected that frame.
MAX_PLAUSIBLE_MATCH_DISTANCE = 60.0

# HSV color ranges for dot classification. GT7's mini-map renders
# opponent cars as small white/light-grey dots and the player's own car
# as a distinct bright marker (commonly red/orange depending on team
# color settings) -- these ranges are intentionally conservative
# starting points and are the first thing to re-tune against a real
# captured mini-map frame if dot detection misses cars or misclassifies
# the player marker (see detect_dots's docstring for how to do that).
OPPONENT_HSV_LOWER = np.array([0, 0, 180], dtype=np.uint8)
OPPONENT_HSV_UPPER = np.array([180, 60, 255], dtype=np.uint8)
PLAYER_HSV_LOWER = np.array([0, 120, 120], dtype=np.uint8)
PLAYER_HSV_UPPER = np.array([12, 255, 255], dtype=np.uint8)
# Red wraps around hue=0 in HSV -- a second range catches the
# high-hue-end red that the single range above would miss.
PLAYER_HSV_LOWER_WRAP = np.array([168, 120, 120], dtype=np.uint8)
PLAYER_HSV_UPPER_WRAP = np.array([180, 255, 255], dtype=np.uint8)

# A detected contour's pixel area must fall in this range to be
# considered a real car dot rather than noise (too small) or a merged
# blob of implausibly many cars / a UI element (too large). Tune
# against a real frame if dots are a visibly different size.
MIN_DOT_AREA_PX = 3
MAX_DOT_AREA_PX = 250

# Strict static mini-map crop, as real pixel coordinates measured
# against a 4K (3840x2160) GT7 HDMI capture with the Full Circuit Map
# HUD option active: GT7's mini-map is locked to fixed screen-space
# coordinates in the top-right corner (not scaled/repositioned based on
# car count or other HUD state), so -- same approach as ocr_relay.py's
# LEADERBOARD_X_MIN/MAX/Y_MIN/MAX -- a tight, hand-measured bounding
# box is used directly rather than a percentage-of-frame region, and is
# scaled proportionally for other capture resolutions (e.g. 1080p) via
# MINIMAP_REFERENCE_WIDTH/HEIGHT below rather than needing a second
# hardcoded coordinate set per resolution.
MINIMAP_REFERENCE_WIDTH = 3840
MINIMAP_REFERENCE_HEIGHT = 2160

MINIMAP_X_MIN = 3040
MINIMAP_X_MAX = 3770
MINIMAP_Y_MIN = 70
MINIMAP_Y_MAX = 680


def _scale_minimap_box(x_min, x_max, y_min, y_max, frame_width, frame_height):
    """Scales a box measured against the 4K reference frame to the
    actual captured frame's resolution (e.g. 1080p), preserving GT7's
    HUD proportions rather than assuming a fixed pixel box regardless
    of capture resolution -- mirrors ocr_relay.py's _scale_box."""
    scale_x = frame_width / MINIMAP_REFERENCE_WIDTH
    scale_y = frame_height / MINIMAP_REFERENCE_HEIGHT
    return (
        int(x_min * scale_x),
        int(x_max * scale_x),
        int(y_min * scale_y),
        int(y_max * scale_y),
    )


def crop_minimap_roi(
    frame_bgr: np.ndarray,
    x_min: int | None = None,
    x_max: int | None = None,
    y_min: int | None = None,
    y_max: int | None = None,
) -> np.ndarray:
    """Crops the top-right full-circuit mini-map region out of a raw
    captured frame. With no arguments, uses the hand-measured
    MINIMAP_X_MIN/MAX/Y_MIN/MAX box above, scaled from its 4K reference
    to the actual frame's resolution (so this works unchanged against
    a 1080p or 4K capture). Explicit x_min/x_max/y_min/y_max can still
    be passed to override that default entirely -- e.g. if a different
    HUD mini-map layout (not Full Circuit Map) is ever supported and
    needs its own measured box.
    """
    height, width = frame_bgr.shape[:2]
    if x_min is None or x_max is None or y_min is None or y_max is None:
        x_min, x_max, y_min, y_max = _scale_minimap_box(
            MINIMAP_X_MIN, MINIMAP_X_MAX, MINIMAP_Y_MIN, MINIMAP_Y_MAX, width, height
        )
    x_min, x_max = max(0, x_min), min(width, x_max)
    y_min, y_max = max(0, y_min), min(height, y_max)
    return frame_bgr[y_min:y_max, x_min:x_max]


class TrackSpline:
    """An ordered, closed-loop track outline, normalized to a 1D lap
    progress coordinate s in [0, LAP_PROGRESS_MAX). Every car's
    position is ultimately expressed as a point along THIS coordinate,
    not raw mini-map (x, y) -- this is what turns "is car A ahead of
    car B" into a trivial 1D comparison (modulo lap wraparound) instead
    of needing any understanding of the track's actual 2D shape at
    runtime.
    """

    def __init__(self, points_xy: list[tuple[float, float]]):
        """points_xy: an ORDERED list of (x, y) mini-map pixel
        coordinates tracing the track outline once around, in the
        direction cars actually drive (matters for lap-progress
        direction, not just shape). The loop is closed automatically
        (the last point connects back to the first), so don't repeat
        the first point at the end.
        """
        if len(points_xy) < 3:
            raise ValueError("TrackSpline needs at least 3 points to form a closed loop")

        self._points = np.asarray(points_xy, dtype=np.float64)

        # Cumulative arc length (real pixel distance) around the loop,
        # ending back at the start -- this is the raw (unnormalized)
        # "distance traveled" coordinate that LAP_PROGRESS_MAX-normalized
        # lap_progress_s is derived from below.
        deltas = np.diff(np.vstack([self._points, self._points[:1]]), axis=0)
        segment_lengths = np.hypot(deltas[:, 0], deltas[:, 1])
        self._cumulative_length = np.concatenate([[0.0], np.cumsum(segment_lengths)])
        self._total_length = self._cumulative_length[-1]
        if self._total_length <= 0:
            raise ValueError("TrackSpline points produce a zero-length loop")

        # A KD-tree over the raw points for fast nearest-point lookup --
        # a real track outline is usually a few hundred points at most,
        # so this isn't strictly required for performance, but it's a
        # cheap way to keep project() fast if a denser outline is ever
        # loaded (e.g. extracted from a traced mini-map image rather
        # than hand-placed waypoints).
        self._kdtree = cKDTree(self._points)

    @classmethod
    def build_from_points(cls, points_xy: list[tuple[float, float]]) -> "TrackSpline":
        """Clean, explicit initialization helper -- construct directly
        from a manually-traced or externally-extracted ordered list of
        (x, y) mini-map pixel coordinates. This is the primary/
        recommended way to build a TrackSpline: trace the track outline
        once (e.g. by clicking waypoints around a screenshot of the
        mini-map in any image tool, or via a one-off contour-extraction
        script), save the points, and load them here.
        """
        return cls(points_xy)

    @classmethod
    def load_from_json(cls, path: str | Path) -> "TrackSpline":
        """Loads a previously-saved list of [x, y] points from a JSON
        file (see save_to_json) -- the usual way to reuse a traced
        track outline across sessions without re-tracing it every
        time the app starts.
        """
        with open(path) as f:
            points = json.load(f)
        return cls([tuple(p) for p in points])

    def save_to_json(self, path: str | Path) -> None:
        with open(path, "w") as f:
            json.dump(self._points.tolist(), f)

    @property
    def total_length_px(self) -> float:
        return float(self._total_length)

    def project(self, x: float, y: float, snap_radius_px: float = SNAP_RADIUS_PX):
        """Projects a single detected dot (x, y) onto the nearest point
        on the track outline, returning its normalized lap_progress_s
        in [0, LAP_PROGRESS_MAX), or None if the dot is farther than
        snap_radius_px from every point on the outline (e.g. a false
        detection well off the track, not a car in the pit lane -- pit
        lanes within snap_radius_px of the main loop are intentionally
        still caught, per the generous default radius).
        """
        distance, index = self._kdtree.query([x, y])
        if distance > snap_radius_px:
            return None

        arc_length = self._cumulative_length[index]
        return (arc_length / self._total_length) * LAP_PROGRESS_MAX

    def project_many(self, points_xy: np.ndarray, snap_radius_px: float = SNAP_RADIUS_PX) -> list[float | None]:
        """Vectorized convenience wrapper over project() for a batch of
        detected dots in one call (e.g. every blob found in a single
        frame) -- same snap/None semantics as project().
        """
        if len(points_xy) == 0:
            return []
        distances, indices = self._kdtree.query(points_xy)
        results = []
        for distance, index in zip(distances, indices):
            if distance > snap_radius_px:
                results.append(None)
            else:
                arc_length = self._cumulative_length[index]
                results.append((arc_length / self._total_length) * LAP_PROGRESS_MAX)
        return results


def circular_distance(a: float, b: float, modulus: float = LAP_PROGRESS_MAX) -> float:
    """Shortest distance between two lap-progress values on a circular
    (wraparound) track, e.g. circular_distance(995, 5) == 10, not 990 --
    this is the metric EVERY downstream comparison (prediction error,
    Hungarian cost, overtake detection) needs to use instead of naive
    subtraction, or a car crossing the start/finish line would look
    like it teleported backward by almost a full lap.
    """
    raw = abs(a - b) % modulus
    return min(raw, modulus - raw)


def circular_delta(previous_s: float, current_s: float, modulus: float = LAP_PROGRESS_MAX) -> float:
    """Signed forward progress from previous_s to current_s around the
    circular track (always >= 0 for a car moving forward, even across
    a start/finish wraparound) -- this is what lets velocity_ds and lap
    counting treat "999 -> 2" as "+3 forward", not a huge backward jump.
    Assumes the car only ever moves forward by less than half a lap
    between consecutive samples (true at any reasonable sample rate).
    """
    return (current_s - previous_s) % modulus


@dataclass
class CarState:
    """Tracked state for a single car, in 1D lap-progress space. One of
    these exists for every one of the 16 grid slots for the whole race
    -- a car is never "dropped" just because its dot wasn't
    individually resolvable this frame (see MinimapTracker.update's
    merged-blob handling), only ever re-labeled via
    sync_with_ocr_standings if the tracker's own guess turns out wrong.
    """

    driver_name: str
    lap_progress_s: float = 0.0
    velocity_ds: float = 0.0
    laps_completed: int = 0

    # True only for the single car representing the player's own
    # vehicle -- see MinimapTracker.player_driver_name. The player's
    # dot is unambiguous (distinct color), so this car's lap_progress_s
    # is always taken directly from the player-colored detection, never
    # from the Hungarian assignment used for the other 15.
    is_player: bool = False

    # How many consecutive frames this car has gone without a
    # confidently-assigned dot of its own (i.e. it's "riding along"
    # inside a merged blob with another car, per the merged-blob
    # handling in MinimapTracker.update) -- purely diagnostic/for
    # tuning, not used in any decision logic itself.
    frames_since_own_detection: int = 0

    def advance(self, measured_s: float | None, dt_seconds: float) -> None:
        """Updates this car's position/velocity/lap count for one
        frame. If measured_s is None (this car didn't get its own
        detected blob this frame -- it's inside a merged blob with
        another car), its position is DEAD-RECKONED forward using its
        last known velocity_ds instead of standing still, which is what
        "rely on their individual velocities to carry them through the
        overlap until the blobs split again" means in practice.
        """
        if measured_s is None:
            predicted_s = (self.lap_progress_s + self.velocity_ds * dt_seconds) % LAP_PROGRESS_MAX
            self._apply_new_s(predicted_s)
            self.frames_since_own_detection += 1
            return

        delta = circular_delta(self.lap_progress_s, measured_s)
        if dt_seconds > 0:
            instantaneous_ds = delta / dt_seconds
            if abs(instantaneous_ds) >= MIN_MEANINGFUL_DS_PER_FRAME:
                self.velocity_ds = (
                    VELOCITY_SMOOTHING_ALPHA * instantaneous_ds
                    + (1 - VELOCITY_SMOOTHING_ALPHA) * self.velocity_ds
                )
        self._apply_new_s(measured_s)
        self.frames_since_own_detection = 0

    def _apply_new_s(self, new_s: float) -> None:
        # A new s that's numerically SMALLER than the old one only
        # means "crossed the start/finish line" (a genuine new lap) if
        # the car was already near the end of the lap -- otherwise a
        # small negative-looking delta is just normal frame-to-frame
        # jitter near a fixed point, not a lap completing. Comparing
        # against LAP_PROGRESS_MAX * 0.5 as the wraparound threshold
        # means a car has to have covered at least half the lap's
        # length forward before a "wrap" is credited, which real lap
        # transitions always will have (the alternative -- jitter --
        # moves at most a few units per frame).
        if new_s < self.lap_progress_s and (self.lap_progress_s - new_s) > LAP_PROGRESS_MAX * 0.5:
            self.laps_completed += 1
        self.lap_progress_s = new_s


@dataclass
class _Detection:
    x: float
    y: float
    lap_progress_s: float


class MinimapTracker:
    """Tracks all 16 cars' lap-progress position via the mini-map,
    independently of (and completely decoupled from) the leaderboard
    OCR relay -- the only integration point with that module is
    sync_with_ocr_standings(), called from the shared main loop with
    whatever ground-truth {driver_name: race_position} the OCR module
    already produced that frame.
    """

    def __init__(self, track_spline: TrackSpline, driver_names_in_grid_order: list[str], player_driver_name: str):
        """driver_names_in_grid_order: all 16 drivers, in STARTING GRID
        order (pole position first) -- used only to seed each car's
        initial lap_progress_s spread out along the grid at t=0, not
        assumed to stay accurate as the race progresses (that's the
        whole point of tracking + OCR re-anchoring below).
        """
        self.track_spline = track_spline
        self.player_driver_name = player_driver_name

        car_count = len(driver_names_in_grid_order)
        self.cars: list[CarState] = [
            CarState(
                driver_name=name,
                # Spread starting grid positions slightly apart along
                # the spline (rather than all at s=0) so the very first
                # frame's Hungarian assignment isn't working from a
                # degenerate all-cars-identical starting state.
                lap_progress_s=(LAP_PROGRESS_MAX - (index * (LAP_PROGRESS_MAX / max(car_count, 1)) / 10)) % LAP_PROGRESS_MAX,
                is_player=(name == player_driver_name),
            )
            for index, name in enumerate(driver_names_in_grid_order)
        ]

    def car_by_name(self, driver_name: str) -> CarState | None:
        return next((c for c in self.cars if c.driver_name == driver_name), None)

    def standings(self) -> list[str]:
        """Returns driver names in the tracker's current best-guess
        race order (leader first), purely from accumulated
        laps_completed + lap_progress_s -- this is what
        sync_with_ocr_standings compares against the real OCR ground
        truth to detect/correct swapped identities.
        """
        ordered = sorted(self.cars, key=lambda c: (-c.laps_completed, -c.lap_progress_s))
        return [c.driver_name for c in ordered]

    def detect_dots(self, minimap_bgr: np.ndarray) -> tuple[list[tuple[float, float]], tuple[float, float] | None]:
        """Finds every car dot in a cropped mini-map frame via HSV
        color thresholding, returning (opponent_dot_centroids,
        player_dot_centroid_or_None). Separated as its own method
        (rather than inlined into update()) so it can be re-tuned/
        tested against a real captured mini-map frame in isolation --
        if cars are being missed or the player marker isn't being
        found, start by visualizing the two masks this method builds
        (cv2.inRange against OPPONENT_HSV_LOWER/UPPER and the two
        PLAYER_HSV_* ranges) against a real frame and adjust those
        constants at the top of this file.
        """
        hsv = cv2.cvtColor(minimap_bgr, cv2.COLOR_BGR2HSV)

        opponent_mask = cv2.inRange(hsv, OPPONENT_HSV_LOWER, OPPONENT_HSV_UPPER)
        player_mask = cv2.inRange(hsv, PLAYER_HSV_LOWER, PLAYER_HSV_UPPER) | cv2.inRange(
            hsv, PLAYER_HSV_LOWER_WRAP, PLAYER_HSV_UPPER_WRAP
        )
        # The player's marker is also bright/white-ish at its edges on
        # some HUD themes and can bleed into the opponent mask -- remove
        # any overlap so a single dot is never double-counted as both.
        opponent_mask = cv2.bitwise_and(opponent_mask, cv2.bitwise_not(player_mask))

        opponent_centroids = self._contour_centroids(opponent_mask)
        player_centroids = self._contour_centroids(player_mask)

        # The player marker should be unambiguous (exactly one blob) --
        # if more than one is found (e.g. a UI element coincidentally
        # matching the color range), take whichever was found first
        # rather than guessing wrong and silently picking noise.
        player_centroid = player_centroids[0] if player_centroids else None

        return opponent_centroids, player_centroid

    @staticmethod
    def _contour_centroids(mask: np.ndarray) -> list[tuple[float, float]]:
        contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        scored: list[tuple[float, tuple[float, float]]] = []
        for contour in contours:
            area = cv2.contourArea(contour)
            if area < MIN_DOT_AREA_PX or area > MAX_DOT_AREA_PX:
                continue
            moments = cv2.moments(contour)
            if moments["m00"] == 0:
                continue
            centroid = (moments["m10"] / moments["m00"], moments["m01"] / moments["m00"])
            scored.append((area, centroid))
        # Largest-first so a caller taking only the first N (e.g. the
        # player-marker fallback above) prefers a real dot over noise.
        scored.sort(key=lambda item: -item[0])
        return [centroid for _, centroid in scored]

    def update(self, minimap_bgr: np.ndarray, dt_seconds: float) -> None:
        """Processes one frame: detects dots, projects them onto the
        track spline, associates them with tracked cars (via the
        Hungarian algorithm on predicted-vs-measured lap-progress
        distance), and advances every car's state -- including cars
        whose dot merged with another's this frame (see
        CarState.advance's dead-reckoning fallback).
        """
        opponent_xy, player_xy = self.detect_dots(minimap_bgr)

        if player_xy is not None:
            player_s = self.track_spline.project(*player_xy)
            player_car = self.car_by_name(self.player_driver_name)
            if player_car is not None and player_s is not None:
                player_car.advance(player_s, dt_seconds)

        opponent_detections = []
        for x, y in opponent_xy:
            s = self.track_spline.project(x, y)
            if s is not None:
                opponent_detections.append(_Detection(x=x, y=y, lap_progress_s=s))

        opponent_cars = [c for c in self.cars if not c.is_player]
        self._assign_and_advance(opponent_cars, opponent_detections, dt_seconds)

    def _assign_and_advance(self, cars: list[CarState], detections: list[_Detection], dt_seconds: float) -> None:
        """Associates predicted car positions with this frame's
        detected blobs via the Hungarian algorithm (scipy's
        linear_sum_assignment), using CIRCULAR lap-progress distance as
        the cost -- then advances every car, whether or not it got an
        unambiguous detection this frame.

        When there are FEWER detections than cars (the merged-blob
        case this whole module exists to handle), linear_sum_assignment
        itself only ever produces a one-to-one matching up to
        min(len(cars), len(detections)) -- it cannot natively assign
        two cars to the same blob. So after the one-to-one solve, any
        car left unmatched is given a SECOND chance to match against
        whichever blob (already claimed or not) is closest to its own
        predicted position, within MAX_PLAUSIBLE_MATCH_DISTANCE -- this
        is what "allow multiple predicted cars to share the same merged
        blob centroid" means in practice: the Hungarian solve picks the
        best unique pairing first, and any leftover cars still snap to
        the nearest plausible (possibly already-used) blob rather than
        going fully blind.
        """
        if not cars:
            return

        predicted_s = {id(car): (car.lap_progress_s + car.velocity_ds * dt_seconds) % LAP_PROGRESS_MAX for car in cars}

        if not detections:
            for car in cars:
                car.advance(None, dt_seconds)
            return

        cost_matrix = np.array(
            [[circular_distance(predicted_s[id(car)], d.lap_progress_s) for d in detections] for car in cars]
        )

        row_indices, col_indices = linear_sum_assignment(cost_matrix)

        matched_s: dict[int, float] = {}
        for row, col in zip(row_indices, col_indices):
            if cost_matrix[row, col] <= MAX_PLAUSIBLE_MATCH_DISTANCE:
                matched_s[row] = detections[col].lap_progress_s

        # Leftover cars (either because there were fewer detections
        # than cars, or because their best Hungarian-assigned match was
        # farther than MAX_PLAUSIBLE_MATCH_DISTANCE and got rejected
        # above) each independently snap to whichever detection is
        # closest to THEIR OWN predicted position, even if another car
        # already claimed that same detection -- this is the
        # "multiple cars share a merged blob centroid" behavior.
        for row, car in enumerate(cars):
            if row in matched_s:
                continue
            distances = [circular_distance(predicted_s[id(car)], d.lap_progress_s) for d in detections]
            best_index = int(np.argmin(distances))
            if distances[best_index] <= MAX_PLAUSIBLE_MATCH_DISTANCE:
                matched_s[row] = detections[best_index].lap_progress_s

        for row, car in enumerate(cars):
            car.advance(matched_s.get(row), dt_seconds)

    def sync_with_ocr_standings(self, confirmed_positions: dict[str, int]) -> None:
        """Ground-truth correction: accepts {driver_name: race_position}
        for however many drivers the leaderboard OCR module confidently
        resolved this frame (typically ~9, the visible HUD rows) and
        re-labels this tracker's car states if its own inferred
        ordering contradicts that ground truth -- e.g. two
        visually-identical dots swapped identities during an off-screen
        pileup the mini-map tracker had no way to disambiguate on its
        own.

        Correction strategy: rather than trusting the mini-map
        tracker's absolute lap_progress_s values (which may have
        drifted/been mis-assigned), this REORDERS the CONFIRMED
        drivers' (lap_progress_s, velocity_ds, laps_completed) tuples
        among themselves to match the OCR's relative order, while
        leaving every unconfirmed car (and the confirmed cars' actual
        kinematic state values) untouched -- this fixes "who is who"
        without discarding the real motion data those state values
        represent, which would otherwise cost the tracker everything
        it had learned about those cars' speed/position up to this
        point.
        """
        confirmed_names = [name for name in confirmed_positions if self.car_by_name(name) is not None]
        if len(confirmed_names) < 2:
            # Nothing to reconcile -- a single confirmed driver has no
            # relative order to contradict.
            return

        # The tracker's OWN inferred order for exactly the confirmed
        # drivers (ignoring every other car), to compare against OCR's.
        tracker_order = [name for name in self.standings() if name in confirmed_names]
        ocr_order = sorted(confirmed_names, key=lambda name: confirmed_positions[name])

        if tracker_order == ocr_order:
            return  # Already agrees -- nothing to correct.

        # Swap the underlying kinematic state (lap_progress_s,
        # velocity_ds, laps_completed) among the confirmed cars so the
        # tracker's state for "whichever car is in P<n>" ends up
        # attached to the driver OCR says is actually in P<n> --
        # identity moves, motion data doesn't.
        tracker_states = [self.car_by_name(name) for name in tracker_order]
        state_values = [(c.lap_progress_s, c.velocity_ds, c.laps_completed) for c in tracker_states]

        for ocr_rank, driver_name in enumerate(ocr_order):
            target_car = self.car_by_name(driver_name)
            lap_progress_s, velocity_ds, laps_completed = state_values[ocr_rank]
            target_car.lap_progress_s = lap_progress_s
            target_car.velocity_ds = velocity_ds
            target_car.laps_completed = laps_completed
