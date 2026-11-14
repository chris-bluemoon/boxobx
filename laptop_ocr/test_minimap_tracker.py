#!/usr/bin/env python3
"""Validation for minimap_tracker.py (the course-map traffic tracker).

- A real 30-second replay recording (test_fixtures/minimap_sequence/,
  the top-right 520x300 corner of each 1080p frame, 1s apart; 15
  opponents on track) checks outline learning, direction and car counts.
- A synthetic circuit checks the distance-to-seconds conversion over a
  full lap, which the 30s recording is too short for.

Run with: python test_minimap_tracker.py
"""
import math

import cv2
import numpy as np

import minimap_tracker as m


def check(label, condition):
    print(f"{'PASS' if condition else 'FAIL'} {label}")
    if not condition:
        raise SystemExit(1)


# --- helpers ---------------------------------------------------------------

def check_circular_delta():
    check("circular_delta goes forward across the line", m.circular_delta(990, 10) == 20)
    check("circular_delta goes backward across the line", m.circular_delta(10, 990) == -20)
    check("circular_delta plain forward", m.circular_delta(100, 150) == 50)


def recorded_frame(i):
    frame = np.zeros((1080, 1920, 3), np.uint8)
    frame[0:300, 1400:1920] = cv2.imread(f"test_fixtures/minimap_sequence/{i:02d}.jpg")
    return frame


# --- real recording ----------------------------------------------------------

def check_real_recording():
    tracker = m.TrafficTracker()
    snapshots = [tracker.update(recorded_frame(i), float(i)) for i in range(30)]

    check("not ready while the outline is still being learned", not any(s.track_ready for s in snapshots[:11]))
    first_ready = next(i for i, s in enumerate(snapshots) if s.track_ready)
    check(f"the outline is learned from the white line (ready at frame {first_ready})", first_ready <= 20)
    check("the learned loop is circuit-sized", 500 < tracker._outline._length < 1000)

    with_cars = [s for s in snapshots if s.cars]
    check("cars are reported once the driving direction is known", len(with_cars) >= 10)
    counts = [sum(c.count for c in s.cars) for s in with_cars]
    check(f"every frame finds 12-18 cars for the 15 on track (got {min(counts)}-{max(counts)})", 12 <= min(counts) and max(counts) <= 18)
    average = sum(counts) / len(counts)
    check(f"car count averages close to 15 (got {average:.1f})", 13.5 <= average <= 16.5)

    progress = [s.player_lap_progress for s in with_cars if s.player_lap_progress is not None]
    forward = sum(1 for a, b in zip(progress, progress[1:]) if m.circular_delta(a, b) >= 0)
    check("the driver's marker moves forward around the lap", forward >= len(progress) - 2)


# --- synthetic circuit ---------------------------------------------------------

CENTRE = (1650, 135)
RADIUS = 90
LAP_SECONDS = 60.0


def synthetic_frame(t, opponent_offsets_seconds, clockwise=True):
    """A white ring with the red driver arrow at angle(t), and blue cars
    a fixed number of seconds behind the driver."""
    frame = np.full((1080, 1920, 3), (150, 110, 70), np.uint8)  # sky-ish blue background
    cv2.circle(frame, CENTRE, RADIUS, (245, 245, 245), 6)

    def point(seconds):
        angle = (1 if clockwise else -1) * 2 * math.pi * seconds / LAP_SECONDS
        return int(CENTRE[0] + RADIUS * math.cos(angle)), int(CENTRE[1] + RADIUS * math.sin(angle))

    for offset in opponent_offsets_seconds:
        cv2.circle(frame, point(t - offset), 4, (240, 200, 120), -1)  # light blue (BGR)
    cv2.circle(frame, point(t), 4, (30, 30, 230), -1)  # red
    return frame


def check_seconds_behind(clockwise):
    tracker = m.TrafficTracker()
    offsets = [3.0, 12.0, 45.0]
    snapshot = None
    t = 0.0
    while t <= 90.0:  # learning + direction + more than a full lap
        snapshot = tracker.update(synthetic_frame(t, offsets, clockwise), t)
        t += 1.0
    direction = "clockwise" if clockwise else "anticlockwise"
    check(f"[{direction}] all 3 synthetic cars are found", len(snapshot.cars) == 3)
    check(
        f"[{direction}] lap time is measured from the driver's own trail (got {snapshot.lap_seconds})",
        snapshot.lap_seconds is not None and abs(snapshot.lap_seconds - LAP_SECONDS) < 2.5,
    )
    measured = sorted(c.seconds_behind for c in snapshot.cars if c.seconds_behind is not None)
    check(
        f"[{direction}] each car's seconds-behind matches its real gap (got {[round(x, 1) for x in measured]})",
        len(measured) == 3 and all(abs(a - b) < 1.5 for a, b in zip(measured, offsets)),
    )


def check_relearns_when_map_changes():
    tracker = m.TrafficTracker()
    for i in range(20):
        tracker.update(recorded_frame(i), float(i))
    blank = np.zeros((1080, 1920, 3), np.uint8)
    results = [tracker.update(blank, 20.0 + i) for i in range(m.RELEARN_AFTER_BAD_FRAMES)]
    check("a frame without the map is reported not ready", not results[0].track_ready)
    check("after several frames without the map, the outline is relearned", tracker._outline is None or not tracker._outline.ready)


check_circular_delta()
check_real_recording()
check_seconds_behind(clockwise=True)
check_seconds_behind(clockwise=False)
check_relearns_when_map_changes()
print("\nAll minimap tracker checks passed.")
