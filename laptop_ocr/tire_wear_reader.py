"""
Boxbox Tire Wear HUD Reader

Standalone, fully decoupled module for reading GT7's 4-wheel tire wear
gauge (the small car-icon widget with 4 vertical fill-bars, bottom-left
of the driving HUD) via pixel-color analysis -- NOT OCR. This widget
renders no numbers at all: full grip is a solid white bar, and as the
tire wears the white recedes from the TOP, revealing red underneath
(confirmed against real captured frames: a worn bar is mostly red with
only a small white cap remaining at the top).

Deliberately separate from ocr_relay.py (leaderboard/position OCR) and
minimap_tracker.py (mini-map car tracking) -- this reads a completely
different, fixed HUD region with its own pixel-color logic, no EasyOCR
involved. The only integration point for a caller would be
read_tire_wear(), given a raw captured frame.

Measured calibration (see laptop_ocr/capture_tire_wear_roi.py, used to
produce the real frames this was tuned against):
  - White (full grip) pixels read approximately BGR(220-238, 215-232,
    229-246) -- all three channels high and close to each other.
  - Red (worn) pixels read approximately BGR(50-70, 55-75, 160-210) --
    red channel clearly dominant, blue/green much lower.
  - Each of the 4 wheel bars is a narrow vertical strip; the widget
    renders the two LEFT-side wheel bars (front-left above rear-left)
    in one column and the two RIGHT-side wheel bars (front-right above
    rear-right) in another column, flanking the car icon.
"""
from __future__ import annotations

from dataclasses import dataclass

import cv2
import numpy as np

# Strict static ROI for the tire-wear widget, as real pixel coordinates
# measured against a 1080p (1920x1080) GT7 capture (the HDMI capture
# card used during development only produces 1080p, not the 4K this
# was originally scouted at -- see _scale_box below for how a 4K
# capture is handled without needing a second hardcoded coordinate
# set). Same strict-static-crop approach as ocr_relay.py's
# LEADERBOARD_X_MIN/MAX/Y_MIN/MAX: the widget is locked to a fixed
# screen-space position, not scaled/repositioned based on race state.
REFERENCE_WIDTH = 1920
REFERENCE_HEIGHT = 1080

TIRE_WEAR_X_MIN = 375
TIRE_WEAR_X_MAX = 495
TIRE_WEAR_Y_MIN = 945
TIRE_WEAR_Y_MAX = 1055

# Column spans WITHIN the cropped ROI above (measured against the same
# 1080p reference crop) -- left-side wheel bars (front-left stacked
# above rear-left) and right-side wheel bars (front-right stacked
# above rear-right).
LEFT_BAR_X_MIN = 12
LEFT_BAR_X_MAX = 24
RIGHT_BAR_X_MIN = 96
RIGHT_BAR_X_MAX = 108

# Row spans WITHIN the cropped ROI for the top (front) and bottom
# (rear) bar halves -- measured against the same reference crop. Each
# half is itself the FULL range a bar could occupy; read_bar_wear_percent
# finds the actual white/red split within this range per frame.
FRONT_BAR_Y_MIN = 10
FRONT_BAR_Y_MAX = 55
REAR_BAR_Y_MIN = 60
REAR_BAR_Y_MAX = 105

# BGR thresholds for classifying a pixel as "white" (fresh/remaining
# grip) vs. "red" (worn) vs. neither (background gap between bars) --
# calibrated against real captured frames (see module docstring).
WHITE_MIN_CHANNEL = 180
RED_MIN_RED_CHANNEL = 140
RED_MIN_RED_MINUS_BLUE = 60


def _scale_box(x_min, x_max, y_min, y_max, frame_width, frame_height):
    """Scales a box measured against the 1080p reference frame to the
    actual captured frame's resolution (e.g. 4K), preserving GT7's HUD
    proportions -- mirrors ocr_relay.py's _scale_box exactly."""
    scale_x = frame_width / REFERENCE_WIDTH
    scale_y = frame_height / REFERENCE_HEIGHT
    return (
        int(x_min * scale_x),
        int(x_max * scale_x),
        int(y_min * scale_y),
        int(y_max * scale_y),
    )


def crop_tire_wear_roi(frame_bgr: np.ndarray) -> np.ndarray:
    """Crops the tire-wear widget out of a raw captured frame, scaled
    from the 1080p reference box to the actual frame's resolution."""
    height, width = frame_bgr.shape[:2]
    x_min, x_max, y_min, y_max = _scale_box(
        TIRE_WEAR_X_MIN, TIRE_WEAR_X_MAX, TIRE_WEAR_Y_MIN, TIRE_WEAR_Y_MAX, width, height
    )
    return frame_bgr[y_min:y_max, x_min:x_max]


def _classify_pixel(bgr: np.ndarray) -> str:
    """Classifies a single BGR pixel as 'white' (remaining grip), 'red'
    (worn), or 'other' (background gap/edge noise between bars) -- see
    the module docstring for the real measured BGR ranges this is
    calibrated against."""
    b, g, r = int(bgr[0]), int(bgr[1]), int(bgr[2])
    if b >= WHITE_MIN_CHANNEL and g >= WHITE_MIN_CHANNEL and r >= WHITE_MIN_CHANNEL:
        return "white"
    if r >= RED_MIN_RED_CHANNEL and (r - b) >= RED_MIN_RED_MINUS_BLUE:
        return "red"
    return "other"


def _bar_wear_percent(roi_bgr: np.ndarray, x_min: int, x_max: int, y_min: int, y_max: int) -> float | None:
    """Computes remaining-grip percent for a single wheel's bar by
    scanning down its column span and finding how much of the bar's
    total (white + red, ignoring background) pixel rows are white.

    Returns None if neither white nor red pixels were found at all in
    this span (e.g. the ROI crop is mis-aligned, or this HUD widget
    isn't currently on screen) -- callers should treat None as "no
    reading this frame", not as 0% wear, since 0% would be
    indistinguishable from "completely bald tire" rather than "no
    data".
    """
    white_rows = 0
    red_rows = 0
    for y in range(y_min, y_max):
        row = roi_bgr[y, x_min:x_max]
        # A bar's full width is a solid, uniform colour at any given
        # row -- classifying just the row's mean colour (rather than
        # every individual pixel) is both faster and more robust
        # against a single stray anti-aliased edge pixel at the bar's
        # left/right border.
        mean_bgr = row.mean(axis=0)
        classification = _classify_pixel(mean_bgr)
        if classification == "white":
            white_rows += 1
        elif classification == "red":
            red_rows += 1

    total_rows = white_rows + red_rows
    if total_rows == 0:
        return None
    return (white_rows / total_rows) * 100.0


@dataclass
class TireWearReading:
    """Remaining-grip percent (100 = fresh, 0 = fully worn) for each of
    GT7's 4 wheels, read directly off the HUD's fill-bar widget --
    None for any wheel whose bar couldn't be confidently read this
    frame (see _bar_wear_percent)."""

    front_left_percent: float | None
    front_right_percent: float | None
    rear_left_percent: float | None
    rear_right_percent: float | None

    @property
    def has_any_reading(self) -> bool:
        return any(
            v is not None
            for v in (
                self.front_left_percent,
                self.front_right_percent,
                self.rear_left_percent,
                self.rear_right_percent,
            )
        )

    def to_dict(self) -> dict:
        return {
            "frontLeftPercent": self.front_left_percent,
            "frontRightPercent": self.front_right_percent,
            "rearLeftPercent": self.rear_left_percent,
            "rearRightPercent": self.rear_right_percent,
        }


def read_tire_wear(frame_bgr: np.ndarray) -> TireWearReading:
    """Public entry point: given a raw captured frame, crops the
    tire-wear widget and reads remaining-grip percent for all 4
    wheels. This is the only function an external caller (e.g. the
    main ocr_relay.py capture loop, if/when this is wired in) needs to
    use -- everything else in this module is an implementation detail.
    """
    roi = crop_tire_wear_roi(frame_bgr)

    return TireWearReading(
        front_left_percent=_bar_wear_percent(roi, LEFT_BAR_X_MIN, LEFT_BAR_X_MAX, FRONT_BAR_Y_MIN, FRONT_BAR_Y_MAX),
        front_right_percent=_bar_wear_percent(roi, RIGHT_BAR_X_MIN, RIGHT_BAR_X_MAX, FRONT_BAR_Y_MIN, FRONT_BAR_Y_MAX),
        rear_left_percent=_bar_wear_percent(roi, LEFT_BAR_X_MIN, LEFT_BAR_X_MAX, REAR_BAR_Y_MIN, REAR_BAR_Y_MAX),
        rear_right_percent=_bar_wear_percent(roi, RIGHT_BAR_X_MIN, RIGHT_BAR_X_MAX, REAR_BAR_Y_MIN, REAR_BAR_Y_MAX),
    )
