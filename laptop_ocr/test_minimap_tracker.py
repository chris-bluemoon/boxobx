"""Standalone unit tests for minimap_tracker.py -- run with:
    python3 -m pytest laptop_ocr/test_minimap_tracker.py -v
or (no pytest available):
    python3 laptop_ocr/test_minimap_tracker.py
"""
import math

import numpy as np

from minimap_tracker import (
    CarState,
    MinimapTracker,
    MINIMAP_X_MAX,
    MINIMAP_X_MIN,
    MINIMAP_Y_MAX,
    MINIMAP_Y_MIN,
    TrackSpline,
    circular_delta,
    circular_distance,
    crop_minimap_roi,
)


def _oval_track_points(n: int = 360, radius: float = 100.0) -> list[tuple[float, float]]:
    center = (150.0, 150.0)
    return [
        (center[0] + radius * math.cos(2 * math.pi * i / n), center[1] + radius * math.sin(2 * math.pi * i / n))
        for i in range(n)
    ]


def test_circular_distance_handles_wraparound():
    assert circular_distance(995, 5) == 10
    assert circular_distance(5, 995) == 10
    assert circular_distance(100, 200) == 100


def test_circular_delta_forward_progress():
    assert circular_delta(995, 5) == 10
    assert circular_delta(10, 20) == 10
    assert circular_delta(20, 10) == 990


def test_track_spline_project_on_outline_point():
    spline = TrackSpline.build_from_points(_oval_track_points())
    s = spline.project(250.0, 150.0)  # rightmost point of the oval == start
    assert s is not None
    assert s < 5 or s > 995

def test_track_spline_project_rejects_far_point():
    spline = TrackSpline.build_from_points(_oval_track_points())
    assert spline.project(0.0, 0.0, snap_radius_px=15.0) is None


def test_track_spline_save_and_load_roundtrip(tmp_path):
    points = _oval_track_points(n=36)
    spline = TrackSpline.build_from_points(points)
    path = tmp_path / "spline.json"
    spline.save_to_json(path)
    reloaded = TrackSpline.load_from_json(path)
    assert reloaded.total_length_px == spline.total_length_px


def test_car_state_advances_forward_and_counts_laps():
    car = CarState(driver_name="Driver A", lap_progress_s=990.0)
    car.advance(measured_s=5.0, dt_seconds=0.1)
    assert car.laps_completed == 1
    assert car.lap_progress_s == 5.0


def test_car_state_dead_reckons_when_no_detection():
    car = CarState(driver_name="Driver B", lap_progress_s=100.0, velocity_ds=50.0)
    car.advance(measured_s=None, dt_seconds=0.1)
    assert car.lap_progress_s == 105.0
    assert car.frames_since_own_detection == 1


def test_car_state_no_lap_credited_on_small_jitter():
    car = CarState(driver_name="Driver C", lap_progress_s=500.0)
    car.advance(measured_s=499.0, dt_seconds=0.1)
    assert car.laps_completed == 0


def _make_tracker(drivers: list[str], player: str) -> MinimapTracker:
    spline = TrackSpline.build_from_points(_oval_track_points())
    return MinimapTracker(spline, drivers, player)


def test_minimap_tracker_initializes_all_cars_and_marks_player():
    drivers = [f"Driver {i}" for i in range(16)]
    tracker = _make_tracker(drivers, player="Driver 0")
    assert len(tracker.cars) == 16
    player_car = tracker.car_by_name("Driver 0")
    assert player_car is not None and player_car.is_player
    assert sum(1 for c in tracker.cars if c.is_player) == 1


def test_minimap_tracker_detect_dots_separates_player_from_opponents():
    drivers = [f"Driver {i}" for i in range(4)]
    tracker = _make_tracker(drivers, player="Driver 0")

    frame = np.zeros((300, 300, 3), dtype=np.uint8)
    # Two white opponent dots.
    frame[100:106, 100:106] = (255, 255, 255)
    frame[150:156, 150:156] = (255, 255, 255)
    # One red player dot (BGR order: pure red).
    frame[200:206, 200:206] = (0, 0, 255)

    opponents, player = tracker.detect_dots(frame)
    assert len(opponents) == 2
    assert player is not None


def test_sync_with_ocr_standings_corrects_swapped_order():
    drivers = ["Alice", "Bob", "Carol"]
    tracker = _make_tracker(drivers, player="Alice")

    alice = tracker.car_by_name("Alice")
    bob = tracker.car_by_name("Bob")
    carol = tracker.car_by_name("Carol")
    # Force tracker's own guess to have Bob ahead of Carol, but OCR
    # ground truth below says Carol is actually ahead.
    alice.lap_progress_s, alice.laps_completed = 500.0, 2
    bob.lap_progress_s, bob.laps_completed = 400.0, 2
    carol.lap_progress_s, carol.laps_completed = 300.0, 2

    assert tracker.standings()[:3] == ["Alice", "Bob", "Carol"]

    tracker.sync_with_ocr_standings({"Bob": 2, "Carol": 3})
    # No change needed here since OCR agrees with tracker's own order
    # (Bob ahead of Carol) -- sanity check before the actual swap test.
    assert tracker.standings()[:3] == ["Alice", "Bob", "Carol"]

    tracker.sync_with_ocr_standings({"Bob": 3, "Carol": 2})
    assert tracker.standings()[:3] == ["Alice", "Carol", "Bob"]


def test_sync_with_ocr_standings_noop_for_single_confirmed_driver():
    drivers = ["Alice", "Bob"]
    tracker = _make_tracker(drivers, player="Alice")
    before = tracker.standings()
    tracker.sync_with_ocr_standings({"Alice": 1})
    assert tracker.standings() == before


def test_update_advances_player_and_opponents_from_a_frame():
    drivers = [f"Driver {i}" for i in range(3)]
    tracker = _make_tracker(drivers, player="Driver 0")

    frame = np.zeros((300, 300, 3), dtype=np.uint8)
    frame[145:151, 245:251] = (255, 255, 255)  # opponent near oval's right edge
    frame[145:151, 50:56] = (0, 0, 255)  # player (red) near oval's left edge

    tracker.update(frame, dt_seconds=0.1)
    # Should not raise, and every car should still have a finite,
    # in-range lap_progress_s afterward.
    for car in tracker.cars:
        assert 0.0 <= car.lap_progress_s < 1000.0


def test_crop_minimap_roi_default_4k_matches_measured_box():
    frame = np.zeros((2160, 3840, 3), dtype=np.uint8)
    cropped = crop_minimap_roi(frame)
    assert cropped.shape[0] == MINIMAP_Y_MAX - MINIMAP_Y_MIN  # 610
    assert cropped.shape[1] == MINIMAP_X_MAX - MINIMAP_X_MIN  # 730


def test_crop_minimap_roi_scales_down_for_1080p():
    frame = np.zeros((1080, 1920, 3), dtype=np.uint8)
    cropped = crop_minimap_roi(frame)
    assert cropped.shape[0] == int(MINIMAP_Y_MAX * 0.5) - int(MINIMAP_Y_MIN * 0.5)
    assert cropped.shape[1] == int(MINIMAP_X_MAX * 0.5) - int(MINIMAP_X_MIN * 0.5)


def test_crop_minimap_roi_explicit_override():
    frame = np.zeros((2160, 3840, 3), dtype=np.uint8)
    cropped = crop_minimap_roi(frame, x_min=0, x_max=100, y_min=0, y_max=50)
    assert cropped.shape == (50, 100, 3)


if __name__ == "__main__":
    import sys
    import pytest

    sys.exit(pytest.main([__file__, "-v"]))
