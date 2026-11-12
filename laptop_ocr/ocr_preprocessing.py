"""OpenCV pre-processing pipeline for HUD OCR crops.

Separated from ocr_relay.py so the preprocessing steps (grayscale,
highlighted-row inversion, binary threshold, upscale) can be unit
tested and tuned independently of the leaderboard-parsing/row-grouping
logic, and so EasyOCR is fed a clean, high-contrast, dark-text-on-white
image instead of a raw BGR capture-card frame -- small, low-contrast
HUD text (especially the position-number column) is exactly the kind
of image EasyOCR performs worst on without this kind of preprocessing,
and is the most likely root cause of a meaningful share of the OCR
misreads/dropped detections the regex-based filtering in ocr_relay.py
has been reactively patching around.
"""
import cv2
import numpy as np

# Binary threshold cutoff (0-255) applied after grayscale conversion --
# GT7's HUD text is rendered with high contrast against a semi-
# transparent dark background, so a fixed global threshold works well
# once the row's polarity (dark-on-light vs light-on-dark) is known;
# see normalize_row_polarity below for why that check has to happen
# BEFORE this fixed threshold is applied.
BINARY_THRESHOLD = 150

# How much to upscale each cropped cell before OCR -- GT7's HUD text is
# small enough in a 1080p/4K capture that EasyOCR's text detector can
# miss or garble individual characters at native resolution; upscaling
# gives the detector more pixels to work with. INTER_CUBIC (rather than
# the default INTER_LINEAR) is used for the upscale since it produces
# smoother, less blocky edges on small text, which OCR engines are
# generally more accurate against.
UPSCALE_FACTOR = 2.5

# A row/cell is considered "bright" (i.e. the player's own highlighted
# row -- bright background, dark text, the INVERSE of every other
# row's dark background/bright text) if its mean grayscale brightness
# exceeds this value. Calibrated against the same real-race brightness
# readings already used elsewhere in ocr_relay.py (_row_is_highlighted):
# a genuinely highlighted row measures ~137 average brightness versus
# ~50-70 for ordinary rows, so a cutoff of 110 sits clearly between the
# two with margin on both sides.
HIGHLIGHTED_ROW_BRIGHTNESS_THRESHOLD = 110

# EasyOCR allowlist restricting the position-number column's OCR to
# digits only -- the position column never contains anything else
# (confirmed against real race screenshots: position renders as a bare
# 1-2 digit number, see ROW_POSITION_PATTERN in ocr_relay.py), so
# letting EasyOCR's detector consider the full alphabet for this column
# only adds opportunities for a digit to be misread as a visually
# similar letter (e.g. "1" as "I", "0" as "O").
POSITION_DIGIT_ALLOWLIST = "0123456789"


def normalize_row_polarity(gray_cell: np.ndarray) -> np.ndarray:
    """Inverts a grayscale cell if it's bright (the player's own
    highlighted row: bright/white background, dark text) so every cell
    reaching the binary threshold step below is in the SAME polarity
    (dark text on a light background) regardless of which row it came
    from. Without this check, thresholding a bright highlighted-row
    cell the same way as a normal dark row turns the whole cell into a
    solid white block with no readable text left at all, rather than
    correctly-inverted dark text that survives thresholding."""
    mean_brightness = float(gray_cell.mean()) if gray_cell.size else 0.0
    if mean_brightness > HIGHLIGHTED_ROW_BRIGHTNESS_THRESHOLD:
        return cv2.bitwise_not(gray_cell)
    return gray_cell


def preprocess_cell(bgr_cell: np.ndarray) -> np.ndarray:
    """Runs the full pipeline on a single cropped cell (e.g. one row's
    position-number box, or one row's name box): grayscale -> polarity
    normalization (invert the player's bright highlighted row) ->
    binary threshold (strip background track glare/gradient down to
    pure black-and-white) -> upscale (more pixels for EasyOCR's
    detector to work with on small HUD text). Returns an image ready
    to hand directly to EasyOCR.readtext()."""
    if bgr_cell is None or bgr_cell.size == 0:
        return bgr_cell

    gray = cv2.cvtColor(bgr_cell, cv2.COLOR_BGR2GRAY) if bgr_cell.ndim == 3 else bgr_cell
    gray = normalize_row_polarity(gray)

    # After normalize_row_polarity, every cell is in the SAME polarity:
    # dark background, bright text (ordinary rows are already this way;
    # the player's bright highlighted row was just inverted into it).
    # THRESH_BINARY_INV maps bright pixels (the text) to 0 (black) and
    # dark pixels (the background/glare/gradient noise) to 255 (white)
    # -- the opposite of plain THRESH_BINARY -- which is what actually
    # produces dark text on a white background, the polarity OCR
    # engines are tuned to expect, rather than white text on black.
    _, thresholded = cv2.threshold(gray, BINARY_THRESHOLD, 255, cv2.THRESH_BINARY_INV)

    upscaled = cv2.resize(
        thresholded,
        None,
        fx=UPSCALE_FACTOR,
        fy=UPSCALE_FACTOR,
        interpolation=cv2.INTER_CUBIC,
    )
    return upscaled
