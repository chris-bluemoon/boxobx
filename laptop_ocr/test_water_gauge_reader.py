"""Tests for water_gauge_reader.py against real captured frames -- run with:
    python3 -m pytest laptop_ocr/test_water_gauge_reader.py -v
"""
from pathlib import Path

import cv2
import numpy as np

from water_gauge_reader import read_water_percent

FIXTURES_DIR = Path(__file__).parent / "test_fixtures"


def _load(name: str) -> np.ndarray:
    frame = cv2.imread(str(FIXTURES_DIR / name))
    assert frame is not None, f"Could not load fixture {name}"
    return frame


def test_wet_frame_reads_the_fill():
    # Fill top at y=1006 of the 960-1050 bracket.
    assert abs(read_water_percent(_load("water_gauge_47_frame.png")) - 48.9) < 1.5


def test_slightly_drier_frame_reads_lower():
    first = read_water_percent(_load("water_gauge_47_frame.png"))
    second = read_water_percent(_load("water_gauge_45_frame.png"))
    assert second < first
    assert abs(second - 46.7) < 1.5


def test_dry_frames_read_zero_not_the_ticks():
    for name in ["tire_wear_fresh_frame.png", "tire_wear_worn_frame.png", "tire_compound_rs_frame.png"]:
        assert read_water_percent(_load(name)) == 0.0, name


def test_no_gauge_on_screen_is_none():
    assert read_water_percent(np.zeros((1080, 1920, 3), dtype=np.uint8)) is None
    assert read_water_percent(np.full((1080, 1920, 3), 200, dtype=np.uint8)) is None


def test_4k_frame_scales():
    frame = _load("water_gauge_47_frame.png")
    big = cv2.resize(frame, (3840, 2160), interpolation=cv2.INTER_NEAREST)
    assert abs(read_water_percent(big) - read_water_percent(frame)) < 1.5
