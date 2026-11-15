#!/usr/bin/env python3
"""Standalone validation for reread_position_column and its wiring
into parse_leaderboard via position_reread_fn -- the supplementary
preprocessed, digit-only re-read for a row whose position number the
initial single-pass (unprocessed) OCR failed to detect at all.
"""
import numpy as np

from ocr_relay import reread_position_column, parse_leaderboard, POSITION_DIGIT_ALLOWLIST


def check(label, condition):
    print(f"{'PASS' if condition else 'FAIL'} {label}")
    if not condition:
        raise SystemExit(1)


class FakeReader:
    """Stands in for easyocr.Reader -- records the allowlist/image it
    was called with and returns a pre-programmed result, so the test
    doesn't need the real (slow, model-downloading) EasyOCR engine."""

    def __init__(self, canned_text):
        self.canned_text = canned_text
        self.last_allowlist = None
        self.last_image_shape = None

    def readtext(self, image, detail=1, paragraph=False, allowlist=None):
        self.last_allowlist = allowlist
        self.last_image_shape = image.shape
        if self.canned_text is None:
            return []
        bbox = [[0, 0], [10, 0], [10, 10], [0, 10]]
        return [(bbox, self.canned_text, 0.95)]


def fake_roi(height=450, width=300):
    return np.full((height, width, 3), (55, 48, 44), dtype=np.uint8)


# --- reread_position_column crops only the position column's x-range,
# not the whole row width, and applies the digit-only allowlist. ---
roi = fake_roi()
row_items = [("K. Wilson", 50, 193)]  # name fragment at y=193, x doesn't matter here
reader = FakeReader(canned_text="7")
result = reread_position_column(reader, roi, row_items, roi.shape[1])

check("reread_position_column returns the digits EasyOCR reported", result == "7")
check(
    "reread_position_column passes the digit-only allowlist to EasyOCR",
    reader.last_allowlist == POSITION_DIGIT_ALLOWLIST,
)
check(
    "reread_position_column crops a narrower width than the full ROI (position column only)",
    reader.last_image_shape[1] < roi.shape[1] * 3,  # upscaled but still column-only, not full-width
)

# --- Returns None gracefully when EasyOCR finds nothing ---
empty_reader = FakeReader(canned_text=None)
empty_result = reread_position_column(empty_reader, roi, row_items, roi.shape[1])
check("reread_position_column returns None when EasyOCR finds nothing", empty_result is None)

# --- Returns None gracefully for missing row_items/ROI ---
check("reread_position_column returns None for empty row_items", reread_position_column(reader, roi, [], roi.shape[1]) is None)
check("reread_position_column returns None for a None ROI", reread_position_column(reader, None, row_items, 300) is None)


# --- Wiring into parse_leaderboard: position_reread_fn is only called
# when the initial pass found no position digit for that row, and its
# result (if digit-shaped) patches gridPosition. ---
def box(x, y, w=60, h=20):
    return [[x, y], [x + w, y], [x + w, y + h], [x, y + h]]


# A row with NO position-shaped fragment at all (simulating a dropped
# detection) -- only the driver name was read for this row.
ocr_results_dropped_position = [
    (box(60, 193), "1", 0.9),
    (box(89, 193), "K. Wilson", 0.9),
    (box(60, 233), "Willy Swerve", 0.9),  # position digit MISSING for this row
]

calls = []


def fake_reread_fn(row_items):
    calls.append(row_items)
    return "2"  # simulate successfully recovering the dropped "2"


result_with_reread = parse_leaderboard(
    ocr_results_dropped_position,
    driver_name="Willy Swerve",
    position_reread_fn=fake_reread_fn,
)
check("position_reread_fn is invoked for the row missing a position digit", len(calls) >= 1)
check(
    "a recovered position digit from position_reread_fn is used for gridPosition",
    result_with_reread["gridPosition"] == 2,
)

# --- Without position_reread_fn (and no header tile), the position is
# unknown rather than guessed from the row's place in the list: that
# fallback (own_index + 1) was removed because GT7's leaderboard shows
# the top few cars plus a separate window around ours, so a row's list
# index isn't its position (it reported P7 for a real P12). Unknown is
# 0, which the app treats as "not read"; GridPositionStabilizer keeps the
# last good reading. ---
result_without_reread = parse_leaderboard(
    ocr_results_dropped_position,
    driver_name="Willy Swerve",
)
check(
    "without position_reread_fn, gridPosition is unknown (0), not guessed from the list position",
    not result_without_reread["gridPosition"],
)
check(
    "without position_reread_fn, the rest of the row is still parsed",
    result_without_reread["driverAhead"] == "K. Wilson",
)

print("\nAll reread_position_column checks passed.")
