#!/usr/bin/env python3
"""Standalone validation for the strict static leaderboard crop
(crop_roi/LEADERBOARD_X_MIN/MAX/Y_MIN/MAX), which replaced a wide
percentage-of-frame-width crop (the whole left 20% of the frame, full
height) with a tight, hand-measured bounding box around just the
standings list -- cropped BEFORE OCR runs on it, rather than feeding
OCR a wide region and filtering junk out of the results afterward.
"""
import numpy as np

from ocr_relay import crop_roi, LEADERBOARD_X_MIN, LEADERBOARD_X_MAX, LEADERBOARD_Y_MIN, LEADERBOARD_Y_MAX


def check(label, condition):
    print(f"{'PASS' if condition else 'FAIL'} {label}")
    if not condition:
        raise SystemExit(1)


def fake_frame(width, height):
    return np.full((height, width, 3), (60, 52, 48), dtype=np.uint8)


# --- At the reference 1080p resolution, the crop matches the exact
# hand-measured coordinates with no scaling applied. ---
frame_1080p = fake_frame(1920, 1080)
roi_1080p = crop_roi(frame_1080p)
check(
    "1080p crop width matches the exact measured x-range (340-40=300px)",
    roi_1080p.shape[1] == LEADERBOARD_X_MAX - LEADERBOARD_X_MIN,
)
check(
    "1080p crop height matches the exact measured y-range (780-220=560px)",
    roi_1080p.shape[0] == LEADERBOARD_Y_MAX - LEADERBOARD_Y_MIN,
)

# --- At 4K (exactly 2x the reference resolution), the crop scales
# proportionally rather than using the same absolute pixel box, since
# GT7's own HUD scales with output resolution. ---
frame_4k = fake_frame(3840, 2160)
roi_4k = crop_roi(frame_4k)
check(
    "4K crop width is exactly double the 1080p crop width (proportional scaling)",
    roi_4k.shape[1] == roi_1080p.shape[1] * 2,
)
check(
    "4K crop height is exactly double the 1080p crop height (proportional scaling)",
    roi_4k.shape[0] == roi_1080p.shape[0] * 2,
)

# --- The crop is strictly smaller than the old wide 20%-width/full-
# height approach would have produced, confirming this is a tighter
# bounding box, not just a relabeled version of the old crop. ---
old_style_width = int(1920 * 0.20)  # the old crop_roi's width-only region
old_style_area = old_style_width * 1080  # old crop was full frame height
new_area = roi_1080p.shape[0] * roi_1080p.shape[1]
check(
    "the strict crop covers meaningfully less area than the old wide percentage crop",
    new_area < old_style_area,
)

print("\nAll crop_roi checks passed.")
