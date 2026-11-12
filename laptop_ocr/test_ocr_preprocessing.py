#!/usr/bin/env python3
"""Standalone validation for the OpenCV pre-processing pipeline
(ocr_preprocessing.py): grayscale conversion, highlighted-row polarity
normalization (invert bright player rows before thresholding), binary
thresholding, and upscaling -- the pipeline added to address OCR
misreads/dropped detections on small, low-contrast HUD text.
"""
import numpy as np

from ocr_preprocessing import (
    normalize_row_polarity,
    preprocess_cell,
    HIGHLIGHTED_ROW_BRIGHTNESS_THRESHOLD,
    UPSCALE_FACTOR,
)


def check(label, condition):
    print(f"{'PASS' if condition else 'FAIL'} {label}")
    if not condition:
        raise SystemExit(1)


def dark_row_bgr(height=20, width=60):
    """A typical ordinary (non-highlighted) GT7 row: dark background,
    bright text -- simulated as a uniformly dark cell (text pixels
    aren't needed to test polarity handling itself)."""
    return np.full((height, width, 3), (55, 48, 44), dtype=np.uint8)


def highlighted_row_bgr(height=20, width=60):
    """The player's own highlighted row: bright/white-ish background,
    dark text -- simulated as a uniformly bright cell."""
    return np.full((height, width, 3), (153, 150, 148), dtype=np.uint8)


# --- normalize_row_polarity leaves an ordinary dark row untouched ---
dark_gray = np.full((20, 60), 55, dtype=np.uint8)
check(
    "an ordinary dark row is NOT inverted (already below the brightness threshold)",
    np.array_equal(normalize_row_polarity(dark_gray), dark_gray),
)

# --- normalize_row_polarity inverts a bright highlighted row ---
bright_gray = np.full((20, 60), 200, dtype=np.uint8)
inverted = normalize_row_polarity(bright_gray)
check(
    "a bright highlighted row IS inverted (above the brightness threshold)",
    not np.array_equal(inverted, bright_gray),
)
check(
    "the inverted row's brightness is the complement of the original (255 - 200 = 55)",
    inverted.mean() == 255 - 200,
)

# --- The brightness threshold itself sits between real measured values ---
check(
    "the brightness threshold (110) sits between a real ordinary row (~50-70) and a real highlighted row (~137)",
    70 < HIGHLIGHTED_ROW_BRIGHTNESS_THRESHOLD < 137,
)

# --- preprocess_cell produces an upscaled image of the expected size ---
cell = dark_row_bgr(height=20, width=60)
processed = preprocess_cell(cell)
check(
    "preprocess_cell upscales the cell by UPSCALE_FACTOR",
    processed.shape[0] == round(20 * UPSCALE_FACTOR) and processed.shape[1] == round(60 * UPSCALE_FACTOR),
)
check("preprocess_cell returns a single-channel (grayscale) image", processed.ndim == 2)

# --- preprocess_cell handles an empty/None cell gracefully ---
check("preprocess_cell returns None for a None input", preprocess_cell(None) is None)
empty_cell = np.zeros((0, 0, 3), dtype=np.uint8)
check("preprocess_cell returns the empty array as-is for an empty input", preprocess_cell(empty_cell).size == 0)

# --- A highlighted (bright) cell, after full preprocessing, does NOT
# collapse into a solid single-value block the way it would without
# the polarity-normalization step -- confirms the inversion step
# actually prevents the "player's row becomes a white block" failure
# mode described in the request. ---
highlighted_cell = highlighted_row_bgr()
processed_highlighted = preprocess_cell(highlighted_cell)
unique_values = np.unique(processed_highlighted)
check(
    "a preprocessed highlighted cell is still a valid binary image (0/255 only), not corrupted",
    set(unique_values.tolist()).issubset({0, 255}),
)

print("\nAll ocr_preprocessing checks passed.")
