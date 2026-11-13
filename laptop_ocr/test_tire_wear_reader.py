"""Standalone unit tests for tire_wear_reader.py -- run with:
    python3 -m pytest laptop_ocr/test_tire_wear_reader.py -v

Uses two real captured frames (test_fixtures/tire_wear_*_frame.png,
1920x1080) from an actual GT7 session as fixtures, rather than
synthetic data -- this HUD widget's exact colour/anti-aliasing
behaviour was only discoverable by capturing real frames in the first
place (see laptop_ocr/capture_tire_wear_roi.py), so the regression
coverage here is against that same ground truth, not a guessed
approximation of it.
"""
from pathlib import Path

import cv2
import numpy as np

from tire_wear_reader import (
    TireWearReading,
    _bar_wear_percent,
    _classify_pixel,
    crop_tire_wear_roi,
    read_tire_wear,
)

FIXTURES_DIR = Path(__file__).parent / "test_fixtures"


def _load_fixture(name: str) -> np.ndarray:
    frame = cv2.imread(str(FIXTURES_DIR / name))
    assert frame is not None, f"Could not load fixture {name}"
    return frame


def test_classify_pixel_white():
    assert _classify_pixel(np.array([236, 225, 238])) == "white"


def test_classify_pixel_red():
    assert _classify_pixel(np.array([54, 61, 202])) == "red"


def test_classify_pixel_other_for_background():
    assert _classify_pixel(np.array([80, 80, 89])) == "other"


def test_fresh_tires_read_as_fully_white_on_all_four_wheels():
    frame = _load_fixture("tire_wear_fresh_frame.png")
    reading = read_tire_wear(frame)
    assert reading.front_left_percent == 100.0
    assert reading.front_right_percent == 100.0
    assert reading.rear_left_percent == 100.0
    assert reading.rear_right_percent == 100.0
    assert reading.has_any_reading


def test_worn_tires_read_meaningfully_below_full_grip_on_all_four_wheels():
    frame = _load_fixture("tire_wear_worn_frame.png")
    reading = read_tire_wear(frame)
    # Real captured frame: visually mostly-red bars with only a small
    # white cap remaining at the top -- every wheel should read well
    # below 100% but still above 0% (not a fully bald/empty bar).
    for percent in (
        reading.front_left_percent,
        reading.front_right_percent,
        reading.rear_left_percent,
        reading.rear_right_percent,
    ):
        assert percent is not None
        assert 0.0 < percent < 80.0


def test_worn_tires_read_lower_than_fresh_tires_on_every_wheel():
    fresh = read_tire_wear(_load_fixture("tire_wear_fresh_frame.png"))
    worn = read_tire_wear(_load_fixture("tire_wear_worn_frame.png"))
    assert worn.front_left_percent < fresh.front_left_percent
    assert worn.front_right_percent < fresh.front_right_percent
    assert worn.rear_left_percent < fresh.rear_left_percent
    assert worn.rear_right_percent < fresh.rear_right_percent


def test_bar_wear_percent_returns_none_when_region_has_no_white_or_red():
    # A region that's entirely background (e.g. sampling a blank area
    # of the ROI) should report "no reading" rather than a bogus 0%.
    roi = np.full((110, 120, 3), (80, 80, 90), dtype=np.uint8)
    assert _bar_wear_percent(roi, 12, 24, 10, 55) is None


def test_tire_wear_reading_has_any_reading_false_when_all_none():
    reading = TireWearReading(
        front_left_percent=None, front_right_percent=None, rear_left_percent=None, rear_right_percent=None
    )
    assert not reading.has_any_reading


def test_crop_tire_wear_roi_scales_for_different_resolutions():
    frame_1080p = np.zeros((1080, 1920, 3), dtype=np.uint8)
    frame_4k = np.zeros((2160, 3840, 3), dtype=np.uint8)
    roi_1080p = crop_tire_wear_roi(frame_1080p)
    roi_4k = crop_tire_wear_roi(frame_4k)
    # The 4K crop should be almost exactly double the 1080p crop's
    # dimensions (allowing for integer-truncation rounding).
    assert abs(roi_4k.shape[0] - roi_1080p.shape[0] * 2) <= 2
    assert abs(roi_4k.shape[1] - roi_1080p.shape[1] * 2) <= 2


if __name__ == "__main__":
    import sys
    import pytest

    sys.exit(pytest.main([__file__, "-v"]))
