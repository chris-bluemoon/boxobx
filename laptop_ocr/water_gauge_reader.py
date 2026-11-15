"""
Boxbox Surface Water Gauge Reader

Reads GT7's surface water gauge -- the vertical bar with the tyre-and-
droplet icon, bottom-left of the driving HUD, just left of the tyre
wear widget -- by pixel colour, like tire_wear_reader.py (no OCR: the
gauge has no numbers).

Measured against real 1080p captures (test_fixtures/water_gauge_*_frame
.png, Nurburgring in the rain; tire_wear_*_frame.png, dry):
  - The scale is a bracket from a top line at y=960 to a base line at
    y=1050, with ticks at y=990 and y=1020 -- exactly two thirds and
    one third. Community testing puts the tyre thresholds on those
    ticks: below 33% slicks, 33-66% intermediates, above 66% wets.
  - The fill is light blue (BGR about 232,227,218: bright, blue above
    red), rising from the bottom of the scale. The ticks are neutral
    grey (about 190,188,196) and cross the bar, so they're told apart
    by colour.
  - A dry track shows the empty bracket.

Water percent is read against the bracket (base line 0%, top line
100%), so the 33%/66% thresholds land on GT7's own ticks.
"""
from __future__ import annotations

import numpy as np

REFERENCE_WIDTH = 1920
REFERENCE_HEIGHT = 1080

# Columns inside the bar (the fill spans x=335-346 at 1080p).
BAR_X_MIN = 338
BAR_X_MAX = 344

# The bracket's top and base lines.
SCALE_TOP_Y = 960
SCALE_BASE_Y = 1050

# Rows to search for the fill (between the bracket lines).
FILL_Y_MIN = 961
FILL_Y_MAX = 1049

# A fill pixel: bright, and bluer than it is red.
FILL_MIN_BRIGHTNESS = 170
FILL_MIN_BLUE_OVER_RED = 6

# A bracket line is this much brighter than the empty bar beside it.
SCALE_LINE_MIN_CONTRAST = 40


def _scale(x: int, y: int, width: int, height: int) -> tuple[int, int]:
    return int(round(x * width / REFERENCE_WIDTH)), int(round(y * height / REFERENCE_HEIGHT))


def _scale_line_present(gray_column: np.ndarray, y: int, background: float) -> bool:
    """A bright line within a couple of rows of [y] (already scaled)."""
    window = gray_column[max(0, y - 3):y + 4]
    return window.size > 0 and float(window.max()) - background >= SCALE_LINE_MIN_CONTRAST


def read_water_percent(frame_bgr: np.ndarray) -> float | None:
    """Surface water on the track, 0-100, from the HUD gauge; None if the
    gauge isn't on screen (menus, replays, a HUD layout without it)."""
    height, width = frame_bgr.shape[:2]
    x_min, top = _scale(BAR_X_MIN, SCALE_TOP_Y, width, height)
    x_max, base = _scale(BAR_X_MAX, SCALE_BASE_Y, width, height)
    _, fill_min = _scale(0, FILL_Y_MIN, width, height)
    _, fill_max = _scale(0, FILL_Y_MAX, width, height)

    strip = frame_bgr[:, x_min:x_max].astype(np.float32).mean(axis=1)  # per-row mean BGR
    if strip.shape[0] <= base + 3:
        return None
    gray = strip.mean(axis=1)

    # The bar's empty background: the darkest rows inside the bracket.
    inside = gray[fill_min:fill_max + 1]
    background = float(np.percentile(inside, 10))
    if not (_scale_line_present(gray, top, background) and _scale_line_present(gray, base, background)):
        return None

    blue, red = strip[:, 0], strip[:, 2]
    is_fill = (gray >= FILL_MIN_BRIGHTNESS) & (blue - red >= FILL_MIN_BLUE_OVER_RED)

    # The fill is one run up from the bottom; allow the couple of
    # anti-aliased rows at its foot before the run starts.
    y = fill_max
    while y > fill_max - 6 and not is_fill[y]:
        y -= 1
    if not is_fill[y]:
        return 0.0
    while y - 1 >= fill_min and is_fill[y - 1]:
        y -= 1
    percent = (base - y) / (base - top) * 100
    return round(min(100.0, max(0.0, percent)), 1)
