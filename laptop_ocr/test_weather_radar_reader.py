"""Tests for weather_radar_reader.py against real captured frames -- run with:
    python3 -m pytest laptop_ocr/test_weather_radar_reader.py -v
"""
from pathlib import Path

import cv2
import numpy as np

from weather_radar_reader import CENTRE_X, CENTRE_Y, KM_PER_PX, RadarTracker, radar_visible

FIXTURES_DIR = Path(__file__).parent / "test_fixtures"


def _load(name: str) -> np.ndarray:
    frame = cv2.imread(str(FIXTURES_DIR / name))
    assert frame is not None, f"Could not load fixture {name}"
    return frame


def _read(name: str) -> dict | None:
    return RadarTracker().update(_load(name), 0)


def test_radar_page_detected_only_when_shown():
    for name in ["weather_radar_100km_t00.png", "weather_radar_rain_over_track.png", "weather_radar_empty_water_43.png"]:
        assert radar_visible(_load(name)), name
    # The course map page, and a dry frame with it.
    assert _read("water_gauge_47_frame.png") is None
    assert _read("tire_wear_fresh_frame.png") is None


def test_rain_over_the_track():
    for name in ["weather_radar_rain_over_track.png", "weather_radar_rain_fading.png"]:
        r = _read(name)
        assert r["overTrack"] is True, name
        assert r["nearestRainKm"] == 0.0


def test_empty_radar():
    r = _read("weather_radar_empty_water_43.png")
    assert r["overTrack"] is False
    assert r["coverageAtTrackPercent"] == 0
    assert r["nearestRainKm"] is None


def test_rain_band_closing_in():
    # The first capture: the eastern band drifting towards the circuit,
    # grass showing through the panel in the later frames.
    distances = [_read(f"weather_radar_100km_t{t}.png")["nearestRainKm"] for t in ("00", "31", "63")]
    assert distances[0] > distances[1] > distances[2]
    assert 60 < distances[0] < 85 and 35 < distances[2] < 60


def _synthetic(rain_left_x: float) -> np.ndarray:
    """The empty radar with a block of (blended teal) rain east of the
    circuit, its west edge at [rain_left_x]."""
    frame = _load("weather_radar_empty_water_43.png").copy()
    x0 = int(round(rain_left_x))
    frame[900:1000, x0:1075] = (92, 88, 62)
    return frame


def test_arrival_and_drift_from_rain_moving_in():
    tracker = RadarTracker()
    # Rain 60 px east, closing at 1 px/s.
    result = None
    for t in range(0, 41, 4):
        result = tracker.update(_synthetic(CENTRE_X + 60 - t), float(t))
    gap_px = 60 - 40 - 5  # to the edge of the circuit's radius
    assert abs(result["nearestRainKm"] - 20 * KM_PER_PX) < 2
    assert abs(result["arrivalSeconds"] - gap_px) < 4
    assert abs(result["driftKmPerMin"] - KM_PER_PX * 60) < 15


def test_rain_moving_away_has_no_arrival():
    tracker = RadarTracker()
    result = None
    for t in range(0, 41, 4):
        result = tracker.update(_synthetic(CENTRE_X + 20 + t), float(t))
    assert result["arrivalSeconds"] is None


def test_rain_fading_out_over_the_track():
    tracker = RadarTracker()
    over = _load("weather_radar_rain_over_track.png")
    empty = _load("weather_radar_empty_water_43.png")
    for t in range(0, 16, 3):
        tracker.update(over, float(t))
    result = None
    for t in range(18, 25, 3):
        result = tracker.update(empty, float(t))
    assert result["overTrack"] is False
    assert result["trend"] == "fading"


def test_centre_is_the_crosshair():
    frame = _load("weather_radar_empty_water_43.png")
    gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
    assert gray[int(CENTRE_Y), 900:1000].mean() > 70  # the horizontal line
    assert gray[900:1000, int(CENTRE_X)].mean() > 70  # the vertical line
