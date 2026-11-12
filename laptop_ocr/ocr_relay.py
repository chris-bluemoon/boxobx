#!/usr/bin/env python3
"""
Boxbox Laptop HUD OCR Relay

Captures the HDMI-mirrored PS5 feed from a USB capture card (via OpenCV),
crops a strict, hand-measured leaderboard bounding box (not a wide
percentage-of-frame region), runs OCR at a throttled
~5Hz, parses grid position / rival driver names / gap intervals, and
streams the result as JSON over UDP to the iPhone running Boxbox
(HudOcrService listens on port 33746).
"""
import argparse
import json
import re
import socket
import time

import cv2
import easyocr

from ocr_preprocessing import preprocess_cell, POSITION_DIGIT_ALLOWLIST

UDP_PORT = 33746

# Standalone 1-2 digit position numbers in the left-most column of each
# leaderboard row (e.g. "16", "17", "20"). Deliberately NOT the same as
# matching "P<number>" anywhere in text, since GT7's leaderboard rows
# render as a bare number in their own column, not "P16"/"P17" etc. (see
# bbox_inspect.py output against a real race screenshot).
ROW_POSITION_PATTERN = re.compile(r"^\d{1,2}$")

# GT7's on-screen gap display renders as "+M:SS" (e.g. "+1:51", "+2:00")
# confirmed against a real race screenshot -- NOT decimal seconds like
# "+0.452s" (that was an incorrect assumption in the original design).
# A "+SS.sss" fallback is also matched in case GT7 switches to a
# decimal-seconds format for very close/sub-minute gaps.
#
# IMPORTANT: this must NOT match the "Fastest Lap" row's lap time (e.g.
# "1:53.128", M:SS.mmm with a decimal), which is a completely different
# piece of HUD data that happens to share the "M:SS" prefix shape. The
# negative lookahead below rejects any M:SS match immediately followed
# by ".digits" so a lap time is never misread as a gap.
GAP_MMSS_PATTERN = re.compile(r"[+-]?\s*(\d{1,2}):(\d{2})(?!\.\d)")
GAP_DECIMAL_PATTERN = re.compile(r"[+-]\s*\d+\.\d{1,3}")


def _parse_gap_seconds(text: str):
    """Parses a gap string into total seconds (float), handling both the
    real GT7 "+M:SS" format and a decimal-seconds fallback. Returns None
    if no gap-shaped text is found."""
    mmss_match = GAP_MMSS_PATTERN.search(text)
    if mmss_match:
        minutes, seconds = int(mmss_match.group(1)), int(mmss_match.group(2))
        return minutes * 60 + seconds

    decimal_match = GAP_DECIMAL_PATTERN.search(text)
    if decimal_match:
        return abs(float(decimal_match.group(0)))

    return None

# Known non-driver HUD text that can appear in the same ROI as the
# leaderboard (the "POSITION"/"LAP" header above it, pause-menu options,
# etc.). If a "row" found by the position-number heuristic contains any
# of these words, it's header/menu clutter that got grouped in by
# vertical proximity, not a real leaderboard entry -- reject it.
HEADER_KEYWORDS = {
    "position", "lap", "continue", "retry", "settings", "exit",
    "course", "map", "fl", "final",
}

# GT7's lap counter renders as "<current>/<total>" (e.g. "1/11"), which
# contains no header keyword but is clearly not a driver name -- reject
# any row whose "name" text is just this shape. [IiLl1] tolerates common
# OCR confusions between the digit 1 and the letters I/l (observed live
# as "1/11" misread as "I/1").
LAP_COUNTER_PATTERN = re.compile(r"^[IiLl\d]{1,3}\s*/\s*[IiLl\d]{1,3}$")

# No real driver name is purely numeric/decimal-shaped -- this catches
# stray lap-time/gap fragments from the "Fastest Lap" row (e.g. "10.066")
# that leak through when they don't carry the "+"/"-" sign or ":" that
# the gap/lap-time patterns above look for, so they'd otherwise be
# wrongly treated as part of a driver's name.
NUMERIC_ONLY_PATTERN = re.compile(r"^[\d.:,\s]+$")

# GT7 renders each leaderboard row's car class/model (e.g. "Gr.3",
# "Gr.4", "N300", "F1 GT") on the same line as the driver name, close
# enough vertically that the row-grouper sweeps it in as if it were part
# of the name (observed live: "P Pereira" became "P Pereira F1 GT").
# This matches each of those tokens individually so they're excluded
# the same way gap/numeric fragments already are, rather than only
# catching the whole-row text as one blob (a driver surname could
# otherwise coincidentally contain a substring like "gt").
CAR_CLASS_TOKEN_PATTERN = re.compile(
    r"^(gr\.?\s?[1-4b]|n\d{2,4}|vgt|lmp\d?|f1(\s?gt)?|gt\d?)$",
    re.IGNORECASE,
)

# Driver surnames/names observed live are always title-case ("Jung",
# "Wilson", "Swerve") even when OCR splits a two-part name across rows
# and only the surname fragment survives -- an all-uppercase single
# word is far more likely stray HUD/track-side text that leaked into a
# row (observed live: a sponsor billboard fragment "POLYPHC" misread as
# a driver entry when nothing else on that row was there to reject it).
ALL_CAPS_WORD_PATTERN = re.compile(r"^[A-Z]{3,}$")

# GT7 driver names render as "<Initial>. <Surname>" (e.g. "K. Nobori"),
# but OCR inconsistently reads the period after the initial -- observed
# live as "K. Nobori", "K Nobori" (period dropped), and "K: Nobori" /
# "K; Wilson" (period misread as a colon/semicolon), all for the exact
# same on-screen name across consecutive frames. Without normalizing
# these to one canonical form, NameStabilizer/driverAhead/driverBehind
# treat them as genuinely different names and flicker between whichever
# variant OCR happened to read with higher confidence that frame.
_INITIAL_SURNAME_PATTERN = re.compile(r"^([A-Za-z])\s*[.:;,]?\s+(\S.*)$")

# Every real driver name observed live is clean title case: each word
# starts with one uppercase letter followed only by lowercase letters
# (plus the usual name punctuation/spacing) -- e.g. "K. Nobori", "Willy
# Swerve", "De Simone". Garbled OCR noise from a misread gap/time value
# (observed live: "HoOOn", standing in for driverBehind when nothing
# else on that single-fragment row was there to reject it) has mixed
# case WITHIN a word (a lowercase letter immediately followed by an
# uppercase one, e.g. the "oO" in "HoOOn"), which no real name does --
# this is a much stronger, more general signal than blocklisting
# individual garbled strings one at a time. Trade-off: a genuine PSN
# name with an internal capital (e.g. "McLaren"-style) would also be
# incorrectly rejected -- none have been observed live so far, and this
# is far rarer than the OCR-noise case being guarded against.
MIXED_CASE_WITHIN_WORD_PATTERN = re.compile(r"[a-z][A-Z]")


def _normalize_driver_name(name: str) -> str:
    """Normalizes a reconstructed driver name to a single canonical
    "<Initial>. <Surname>" form, so the same real name is never treated
    as a different one just because OCR did/didn't catch the period
    after the initial (or misread it as a colon/semicolon)."""
    match = _INITIAL_SURNAME_PATTERN.match(name.strip())
    if not match:
        return name.strip()
    initial, rest = match.groups()
    return f"{initial.upper()}. {rest.strip()}"

# Row-grouping tolerance: OCR fragments within this many pixels of each
# other's vertical center are considered part of the same leaderboard
# row (position number + driver name on the same horizontal line).
ROW_Y_TOLERANCE_PX = 25


def list_devices(max_index: int = 10) -> None:
    print("Probing capture devices...")
    for index in range(max_index):
        cap = cv2.VideoCapture(index)
        if cap.isOpened():
            ok, _ = cap.read()
            print(f"  index {index}: {'available' if ok else 'opened but no frame'}")
            cap.release()


# Strict static leaderboard crop, as real pixel coordinates measured
# against a 1080p (1920x1080) GT7 capture: GT7's leaderboard HUD is
# locked to fixed screen-space coordinates (not scaled/repositioned
# based on car count or other HUD state), so a tight, hand-measured
# bounding box around just the standings list is both safe and far
# less likely to sweep in unrelated HUD/menu/billboard text than
# cropping a wide percentage of the frame and filtering junk out after
# the fact. Scaled proportionally for other capture resolutions (e.g.
# 4K) via REFERENCE_WIDTH/REFERENCE_HEIGHT below, rather than needing a
# second hardcoded set of 4K-native coordinates -- GT7's HUD itself
# scales proportionally with output resolution, so this tracks it.
REFERENCE_WIDTH = 1920
REFERENCE_HEIGHT = 1080

# Whole standings list (position + name + gap, every row) -- covers up
# to ~16-20 rows depending on race grid size.
LEADERBOARD_X_MIN = 40
LEADERBOARD_X_MAX = 340
LEADERBOARD_Y_MIN = 220
LEADERBOARD_Y_MAX = 780

# Sub-column boundaries WITHIN the leaderboard crop above (measured as
# ABSOLUTE 1080p frame coordinates: position col x=45-85, name col
# x=90-245, gap col x=250-335; converted below to be relative to
# LEADERBOARD_X_MIN since that's what crop_roi actually crops to).
# Documented here for reference/future use, but NOT currently enforced
# in parse_leaderboard's fragment-tagging logic -- the row-grouping
# heuristics there (position-shape regex, gap-shape regex, driver-name
# casing rules) were built and validated against synthetic test
# fixtures using an earlier, looser x-coordinate convention, and
# retrofitting a hard column cutoff onto that matching logic broke
# several of those existing, real-bug-driven regression tests without
# fixing anything that was actually wrong -- the crop itself (below) is
# the part that needed tightening, and still does the real narrowing
# the strict-static-cropping approach is about.
POSITION_COLUMN_X_MAX = 85 - LEADERBOARD_X_MIN  # position col: x=45-85 -> 5-45 post-crop
NAME_COLUMN_X_MAX = 245 - LEADERBOARD_X_MIN  # name col: x=90-245 -> 50-205 post-crop
# Gap/interval column is everything past NAME_COLUMN_X_MAX up to the
# crop's right edge (x=250-335 absolute -> 210-295 post-crop).


def _scale_box(x_min, x_max, y_min, y_max, frame_width, frame_height):
    """Scales a box measured against the 1080p reference frame to the
    actual captured frame's resolution (e.g. 4K), preserving GT7's HUD
    proportions rather than assuming a fixed pixel box regardless of
    capture resolution."""
    scale_x = frame_width / REFERENCE_WIDTH
    scale_y = frame_height / REFERENCE_HEIGHT
    return (
        int(x_min * scale_x),
        int(x_max * scale_x),
        int(y_min * scale_y),
        int(y_max * scale_y),
    )


def crop_roi(frame, roi_width_pct: float = None):
    """Crops the strict, hand-measured leaderboard bounding box (see
    LEADERBOARD_X_MIN/MAX, LEADERBOARD_Y_MIN/MAX above), scaled to the
    actual frame resolution. roi_width_pct is accepted for backward
    compatibility with existing call sites/CLI flag but is no longer
    used for the crop itself now that an exact box is known -- kept so
    --roi-width-pct doesn't need to be removed from scripts/muscle
    memory immediately."""
    height, width = frame.shape[:2]
    x_min, x_max, y_min, y_max = _scale_box(
        LEADERBOARD_X_MIN, LEADERBOARD_X_MAX, LEADERBOARD_Y_MIN, LEADERBOARD_Y_MAX, width, height
    )
    return frame[y_min:y_max, x_min:x_max]


def _group_into_rows(ocr_results):
    """Groups raw EasyOCR (bbox, text, conf) results into leaderboard
    rows by vertical (y) proximity. Returns a list of rows, each row a
    list of (text, x_min, y_center) tuples sorted left-to-right."""
    items = []
    for bbox, text, _conf in ocr_results:
        ys = [p[1] for p in bbox]
        xs = [p[0] for p in bbox]
        y_center = sum(ys) / len(ys)
        x_min = min(xs)
        items.append((text.strip(), x_min, y_center))

    items.sort(key=lambda item: item[2])  # sort by y_center

    rows = []
    for text, x_min, y_center in items:
        placed = False
        for row in rows:
            if abs(row[0][2] - y_center) <= ROW_Y_TOLERANCE_PX:
                row.append((text, x_min, y_center))
                placed = True
                break
        if not placed:
            rows.append([(text, x_min, y_center)])

    for row in rows:
        row.sort(key=lambda item: item[1])  # left-to-right within a row

    return rows


def _extract_header_position(ocr_results, debug: bool = False) -> int:
    """GT7's position HUD renders as a large standalone digit tile (the
    driver's current position) to the left of a "POSITION" label, with
    "/<total cars>" on a separate line below the label -- confirmed
    against a real race screenshot. The per-row numbered list below is
    a SEPARATE, more reliable source for the same value (see
    parse_leaderboard), so this header reading is a secondary
    cross-check, not the primary source. Returns 0 if it can't be
    confidently located."""
    items = []
    for bbox, text, _conf in ocr_results:
        ys = [p[1] for p in bbox]
        xs = [p[0] for p in bbox]
        items.append((text.strip(), min(xs), sum(ys) / len(ys)))

    position_label = next((item for item in items if item[0].strip().lower() == "position"), None)
    if position_label is None:
        return 0
    _label_text, label_x, label_y = position_label

    # The big position digit tile renders to the LEFT of the "POSITION"
    # label (not below it -- see the real screenshot), roughly
    # vertically aligned with the label.
    candidates = [
        item
        for item in items
        if item[1] < label_x
        and abs(item[2] - label_y) < 30
        and ROW_POSITION_PATTERN.match(item[0])
    ]
    if debug:
        print(f"[debug] POSITION label at x={label_x},y={label_y} -- candidates: {candidates}")

    if not candidates:
        return 0

    closest = min(candidates, key=lambda item: label_x - item[1])
    return int(closest[0])


def _row_is_highlighted(frame_bgr, row_items, roi_width: int) -> bool:
    """GT7 highlights the driver's own row in the standings list with a
    distinctly lighter/red-tinted background versus other rows' plain
    dark background (confirmed against a real race screenshot). Samples
    the average BGR colour across the row's vertical extent (full ROI
    width, so it catches the highlight band regardless of which column
    it starts in) and flags it as highlighted if it's both noticeably
    brighter than a typical dark HUD row AND carries a red/warm tint
    (red channel clearly dominant), rather than e.g. a neutral bright
    patch like a car's headlight glare passing by."""
    if frame_bgr is None or not row_items:
        return False

    ys = [y for _text, _x, y in row_items]
    y_min = max(0, int(min(ys)) - 4)
    y_max = min(frame_bgr.shape[0], int(max(ys)) + 4)
    if y_max <= y_min:
        return False

    band = frame_bgr[y_min:y_max, 0:roi_width]
    if band.size == 0:
        return False

    mean_b, mean_g, mean_r = band.reshape(-1, 3).mean(axis=0)
    brightness = (mean_b + mean_g + mean_r) / 3
    # Thresholds calibrated against two real race screenshots: the
    # genuinely highlighted row measured ~132/125/153 (B/G/R),
    # brightness ~137, clearly red-dominant -- versus OTHER rows
    # measuring anywhere from ~57/48/44 (brightness ~50) up to
    # ~74/67/68 (brightness ~70) with only a marginal red lean, nowhere
    # near the highlighted row's clear brightness + colour jump. An
    # earlier looser threshold (brightness > 55, red only required to
    # not trail the other channels) produced a false positive on an
    # adjacent non-highlighted row that happened to be a bit brighter
    # than usual -- these tighter thresholds require BOTH a much larger
    # brightness jump AND a clear red-channel margin, matching the
    # actual gap observed between a genuinely highlighted row and
    # everything else.
    return brightness > 100 and mean_r > mean_g + 15 and mean_r > mean_b + 15


def reread_position_column(reader, roi_bgr, row_items, roi_width: int):
    """Re-OCRs just a single row's position-number column with the full
    preprocessing pipeline (grayscale -> highlighted-row-polarity
    normalization -> binary threshold -> 2.5x upscale, see
    ocr_preprocessing.py) and a digit-only allowlist, rather than
    relying solely on whatever EasyOCR's single pass over the whole
    (unprocessed) ROI happened to read for that small, low-contrast
    cell. Returns the re-read digits as a string, or None if nothing
    readable was found. This is deliberately a supplementary re-read of
    just the highest-value column (the position number is the
    hardest-to-read, most consequential field -- see
    ROW_POSITION_PATTERN's comment on how often EasyOCR drops it
    entirely at native resolution), not a wholesale replacement of the
    existing whole-ROI OCR pass that still does everything else (names,
    gaps).
    """
    if not row_items or roi_bgr is None or roi_bgr.size == 0:
        return None

    ys = [y for _text, _x, y in row_items]
    y_min = max(0, int(min(ys)) - 6)
    y_max = min(roi_bgr.shape[0], int(max(ys)) + 6)
    # POSITION_COLUMN_X_MAX is measured relative to the crop's own left
    # edge already (see its definition above), so it's used directly
    # here rather than re-adding LEADERBOARD_X_MIN -- that constant is
    # only needed when converting an ABSOLUTE frame coordinate into a
    # post-crop one, which this value already is.
    x_max = min(roi_width, POSITION_COLUMN_X_MAX)
    if y_max <= y_min or x_max <= 0:
        return None

    cell = roi_bgr[y_min:y_max, 0:x_max]
    processed = preprocess_cell(cell)
    if processed is None or processed.size == 0:
        return None

    results = reader.readtext(
        processed,
        detail=1,
        paragraph=False,
        allowlist=POSITION_DIGIT_ALLOWLIST,
    )
    digits = "".join(text.strip() for _bbox, text, _conf in results if text.strip())
    return digits or None


def parse_leaderboard(
    ocr_results,
    driver_name: str,
    frame_bgr=None,
    roi_width: int = 0,
    roi_height: int = 0,
    debug: bool = False,
    position_reread_fn=None,
) -> dict:
    """Finds the driver's own row in the numbered standings list (each
    row: a 1-2 digit position number, driver name, national flag icon
    not OCR'd as text, and sometimes a gap fragment -- confirmed against
    a real race screenshot), preferring the row GT7 visually highlights
    with a distinct red/bright tint (more robust than name OCR, which
    frequently garbles the driver's name) and falling back to a name
    match if no row is confidently highlighted (e.g. frame_bgr wasn't
    supplied, or the highlight colour couldn't be sampled this frame).
    gridPosition is taken from the matched row's own position number,
    cross-checked against the separate header digit tile (see
    _extract_header_position) only as a fallback if the row itself
    didn't carry a parseable position number. Falls back to all-None/0
    fields if the driver's row can't be located by either method.

    position_reread_fn, when provided, is called as
    position_reread_fn(row_items) -> str|None for any row where the
    initial single-pass OCR did NOT find a parseable position digit --
    see reread_position_column, which applies the full preprocessing
    pipeline (grayscale/polarity-normalize/threshold/upscale) and a
    digit-only allowlist to just that row's position cell, a
    supplementary re-read specifically targeting the field most often
    dropped by a single unprocessed OCR pass. Left as None in tests
    (which use the original single-pass behavior), and wired to a real
    preprocessing re-read only in the live capture loop."""
    rows = _group_into_rows(ocr_results)
    header_position = _extract_header_position(ocr_results, debug=debug)

    # With the strict static leaderboard crop (see crop_roi/
    # LEADERBOARD_X_MIN/MAX/Y_MIN/MAX), header/billboard/lap-timer junk
    # from OUTSIDE the standings list is now excluded at the capture
    # stage itself (before OCR even runs on it), rather than needing a
    # second, separate y-bound filter here to catch it after the fact.
    # This retains only a minimal safety margin (a few px at the very
    # top/bottom of the crop) in case OCR occasionally reports a bbox
    # that bleeds slightly past the crop edge, without re-introducing a
    # second hardcoded absolute y-range that would silently go stale
    # the next time the crop itself is re-measured/adjusted.
    if roi_height > 0:
        margin = max(4, int(roi_height * 0.02))
        rows = [
            row
            for row in rows
            if row and margin < min(y for _t, _x, y in row) < roi_height - margin
        ]

    # Confirmed against a real race: a standalone gap value rendered
    # BETWEEN two name rows (e.g. "+3:49" between "K. Nobori" and
    # "Willy Swerve") is that LOWER row's own gap to the car directly
    # ahead of it (i.e. it belongs to the entry about to be appended
    # next, not the one already appended) -- so it's held in
    # pending_gap_to_ahead until the next real entry is built, rather
    # than attached to the previous entry. Separately, the driver's own
    # highlighted row renders its OWN gap merged on the same line as
    # its name -- but that number is the gap to the race LEADER, a
    # different quantity entirely, not gap-to-ahead.
    entries = []
    pending_gap_to_ahead = None
    for row in rows:
        if not row:
            continue

        row_words = set(re.findall(r"[a-z]+", " ".join(text for text, _x, _y in row).lower()))
        if row_words & HEADER_KEYWORDS:
            continue

        row_text_only = [text for text, _x, _y in row]

        if len(row_text_only) == 1 and _parse_gap_seconds(row_text_only[0]) is not None:
            pending_gap_to_ahead = _parse_gap_seconds(row_text_only[0])
            continue

        if len(row_text_only) == 1 and LAP_COUNTER_PATTERN.match(row_text_only[0]):
            continue

        # The per-row position digit (1, 2, 3...) is clearly visible in
        # a real race screenshot, but EasyOCR frequently fails to read
        # it at all (too small/low-contrast against its number tile,
        # confirmed live) -- so it can't be *required* the way the
        # driver name can. When present, it's still used for
        # gridPosition/cross-checking below.
        position_fragment = next(
            (text for text, _x, _y in row if ROW_POSITION_PATTERN.match(text)), None
        )

        # The initial single-pass OCR found nothing for this row's
        # position digit -- give the preprocessing pipeline (grayscale/
        # polarity-normalize/threshold/upscale + digit-only allowlist, see
        # reread_position_column) a chance to recover it from a cleaner
        # re-read of just that small cell, rather than accepting a
        # dropped detection outright.
        if position_fragment is None and position_reread_fn is not None:
            reread = position_reread_fn(row)
            if reread and ROW_POSITION_PATTERN.match(reread):
                position_fragment = reread

        name = " ".join(
            text
            for text, _x, _y in row
            if text != position_fragment
            and _parse_gap_seconds(text) is None
            and not NUMERIC_ONLY_PATTERN.match(text)
            and not CAR_CLASS_TOKEN_PATTERN.match(text.strip())
        )
        if (
            not name
            or LAP_COUNTER_PATTERN.match(name)
            or len(name) > 24
            or ALL_CAPS_WORD_PATTERN.match(name)
            or MIXED_CASE_WITHIN_WORD_PATTERN.search(name)
        ):
            # A standings entry's name is always short (a real driver's
            # PSN name/initial, confirmed against a real race) -- an
            # implausibly long "name" here means unrelated HUD/menu/ad
            # text (e.g. a sponsor billboard graphic) got swept into a
            # row by the y-proximity grouper, not a real driver entry.
            # Mixed case within a word means garbled OCR noise (e.g. a
            # misread gap/time value), not a real name.
            continue
        name = _normalize_driver_name(name)
        # A gap merged inline on this same row (shares a y-position with
        # the name) is the driver's own highlighted-row gap-to-LEADER
        # (confirmed live: rendered in red on the same line as the
        # name) -- a different quantity from gap-to-ahead, which is
        # always the standalone row collected above as
        # pending_gap_to_ahead and belongs to THIS entry.
        inline_gap = next(
            (g for text, _x, _y in row if (g := _parse_gap_seconds(text)) is not None),
            None,
        )
        entries.append(
            {
                "name": name,
                "gap_to_ahead": pending_gap_to_ahead,
                "gap_to_leader": inline_gap,
                "position": int(position_fragment) if position_fragment else None,
                "highlighted": _row_is_highlighted(frame_bgr, row, roi_width),
            }
        )
        pending_gap_to_ahead = None

    # Prefer the highlighted row; only fall back to name matching if no
    # row was confidently highlighted this frame.
    own_index = next((i for i, e in enumerate(entries) if e["highlighted"]), None)

    if own_index is None:
        driver_name_lower = driver_name.lower()
        for index, entry in enumerate(entries):
            # Loose substring match since OCR frequently drops/garbles a
            # character or two (e.g. "Willy Swerve" -> "Wiily Swerve").
            if driver_name_lower in entry["name"].lower() or entry["name"].lower() in driver_name_lower:
                own_index = index
                break

    if own_index is None:
        if debug:
            if not entries:
                print(
                    f"[debug] no driver-name rows detected at all this frame -- "
                    f"grouped rows (text, x, y) per row: {rows}"
                )
            else:
                print(
                    f"[debug] driver row not matched by highlight or name {driver_name!r} -- "
                    f"rows read: {[(e['position'], e['name'], e['highlighted']) for e in entries]}"
                )
        return {
            "gridPosition": header_position,
            "driverAhead": None,
            "driverBehind": None,
            "gapAheadSeconds": None,
            "gapBehindSeconds": None,
            "gapToLeaderSeconds": None,
        }

    own_entry = entries[own_index]
    ahead_entry = entries[own_index - 1] if own_index > 0 else None
    behind_entry = entries[own_index + 1] if own_index + 1 < len(entries) else None

    # gridPosition preference order: (1) the matched row's own OCR'd
    # position digit, when EasyOCR actually read it -- most direct and
    # the only source guaranteed correct regardless of which rows are
    # on screen; (2) the separate header digit tile, as a fallback.
    #
    # own_index + 1 (the row's position WITHIN the parsed list) was
    # REMOVED as a fallback -- it silently assumes the on-screen
    # standings list is a contiguous, unbroken P1-downward list, but
    # GT7's in-race leaderboard frequently is NOT: confirmed live, it
    # shows the top few cars (e.g. P2-P3) PLUS a separate sliding
    # window around the driver's own car (e.g. P8-P12), with a gap in
    # between and no rows for the positions skipped over. own_index+1
    # in that situation reports "this row's rank among the rows that
    # happened to be visible/OCR'd this frame", not the driver's real
    # on-screen position -- e.g. own row being the 7th of 7 visible
    # entries reported gridPosition=7 while the row's own digit (and
    # reality) was P12. This was the root cause of a reported bug
    # (restarting a race in P5, displayed as P4) that GridPositionStabilizer
    # alone could not fix, since the WRONG value was being read
    # consistently enough to pass the stability check.
    grid_position = own_entry["position"] or header_position

    # gapAheadSeconds is OUR gap to the car directly ahead (our own
    # gap_to_ahead); gapBehindSeconds is the car directly behind's gap
    # to US, i.e. that entry's own gap_to_ahead viewed from the other
    # side -- both come from the standalone gap row between two name
    # rows (see pending_gap_to_ahead above). gapToLeaderSeconds is a
    # separate quantity entirely: OUR OWN row's inline red gap number,
    # confirmed live to be the gap to the race leader, not to the car
    # ahead.
    return {
        "gridPosition": grid_position,
        "driverAhead": ahead_entry["name"] if ahead_entry else None,
        "driverBehind": behind_entry["name"] if behind_entry else None,
        "gapAheadSeconds": own_entry["gap_to_ahead"],
        "gapBehindSeconds": behind_entry["gap_to_ahead"] if behind_entry else None,
        "gapToLeaderSeconds": own_entry["gap_to_leader"],
    }


_NO_CANDIDATE = object()  # sentinel: distinct from a tracked candidate of None


class NameStabilizer:
    """Smooths driver-ahead/driver-behind name flicker across consecutive
    OCR samples (e.g. "G. Howe" one frame, "Howe" the next, due to a
    low-confidence single-letter initial being dropped). Keeps the
    longest/most-complete name seen recently for each role, and only
    resets to a shorter/different name once that different reading has
    been stable for a few consecutive samples -- which is what a genuine
    standings change (not just OCR noise) looks like.

    A missing reading (new_name is None -- no row found for that role)
    is treated the same way as any other "different reading": it only
    replaces the current value once seen consistently for a few samples
    in a row. This matters because None covers two very different real
    situations that look identical from a single frame: a transient OCR
    miss (car briefly not detected mid-race -- should NOT cause a blank
    flicker), and a genuine, permanent absence (e.g. driverBehind is
    always None once you're in last place -- should eventually stick
    once confirmed, rather than leaving a stale name on screen
    forever)."""

    def __init__(self, stability_threshold: int = 2):
        self._stability_threshold = stability_threshold
        self._current = {"ahead": None, "behind": None}
        self._candidate = {"ahead": _NO_CANDIDATE, "behind": _NO_CANDIDATE}
        self._candidate_count = {"ahead": 0, "behind": 0}

    def update(self, role: str, new_name):
        current = self._current[role]

        # Same reading as what's already accepted (including both being
        # None, or the new reading being a substring of the current
        # name, e.g. "Howe" is a substring of "G. Howe") -- keep
        # whichever is longer/more complete, no candidate tracking
        # needed.
        if new_name is None and current is None:
            return None
        if current is not None and new_name is not None and (new_name in current or current in new_name):
            if len(new_name) > len(current):
                self._current[role] = new_name
            self._candidate_count[role] = 0
            return self._current[role]

        # First-ever reading for this role (no prior accepted value) --
        # accept immediately rather than waiting out the stability
        # window, since there's nothing stale on screen to protect
        # against yet.
        if current is None:
            self._current[role] = new_name
            self._candidate[role] = _NO_CANDIDATE
            self._candidate_count[role] = 0
            return new_name

        # A genuinely different reading (a different name, or a name
        # disappearing to None, or None resolving into a name) -- only
        # accept it once it's been read consistently for a few samples
        # in a row, to avoid a single noisy OCR misread (or momentary
        # miss) causing a spurious change.
        if self._candidate[role] == new_name:
            self._candidate_count[role] += 1
        else:
            self._candidate[role] = new_name
            self._candidate_count[role] = 1

        if self._candidate_count[role] >= self._stability_threshold:
            self._current[role] = new_name
            self._candidate[role] = _NO_CANDIDATE
            self._candidate_count[role] = 0

        return self._current[role]


class GridPositionStabilizer:
    """Smooths gridPosition flicker across consecutive OCR samples, the
    same way NameStabilizer smooths driverAhead/driverBehind.

    gridPosition is computed fresh every frame from a fallback chain
    (own row's OCR'd position digit, else the row's index within the
    parsed standings list, else the header digit tile -- see
    parse_leaderboard) with NO debouncing of its own, unlike every
    other leaderboard field (driverAhead/driverBehind go through
    NameStabilizer, gaps go through GapTracker's rolling window). In
    practice this means a single noisy frame -- the highlighted-row
    detector mis-firing on a neighbouring row due to glare, a row
    getting dropped from the y-proximity grouping and shifting
    own_index by one, or a garbled position digit -- immediately
    flickers the position shown on screen even while genuinely holding
    station (confirmed live: reported as e.g. holding P5 but the HUD
    alternating P5/P6). Requiring a different reading to repeat for a
    few consecutive samples before accepting it (same approach as
    NameStabilizer) filters this out while still responding quickly to
    a real overtake."""

    def __init__(self, stability_threshold: int = 3):
        self._stability_threshold = stability_threshold
        self._current = None
        self._candidate = None
        self._candidate_count = 0

    def update(self, new_position):
        # A missing/zero reading (driver row not located this frame)
        # is treated as "no update" rather than a real position change
        # -- keep showing the last confirmed position rather than
        # flickering to 0/None on a transient OCR miss.
        if not new_position:
            return self._current

        if self._current is None:
            self._current = new_position
            self._candidate = None
            self._candidate_count = 0
            return self._current

        if new_position == self._current:
            self._candidate = None
            self._candidate_count = 0
            return self._current

        if self._candidate == new_position:
            self._candidate_count += 1
        else:
            self._candidate = new_position
            self._candidate_count = 1

        if self._candidate_count >= self._stability_threshold:
            self._current = new_position
            self._candidate = None
            self._candidate_count = 0

        return self._current


class GapTracker:
    """Tracks whether the time gap to the car ahead/behind is closing,
    growing, or steady, by comparing the current gap reading against a
    short rolling window of recent readings (rather than just the
    immediately previous sample, which would be too sensitive to a
    single noisy OCR misread of the gap digits).

    This is the actual metric useful for race strategy calls ("we're
    closing the gap" / "they're pulling away") -- just showing who's
    ahead/behind by name is something the driver can already see
    directly on screen."""

    def __init__(self, window_size: int = 5, min_change_seconds: float = 0.3):
        self._window_size = window_size
        self._min_change_seconds = min_change_seconds
        self._history = {"ahead": [], "behind": [], "leader": []}

    def update(self, role: str, gap_seconds):
        history = self._history[role]

        if gap_seconds is None:
            # No current reading (car out of view / gap not visible) --
            # don't let a gap of missing data corrupt the trend; just
            # report steady/unknown and keep the history as-is in case
            # the same car's gap reappears shortly after.
            return {"gapSeconds": None, "trend": "unknown"}

        history.append(gap_seconds)
        if len(history) > self._window_size:
            history.pop(0)

        if len(history) < 2:
            return {"gapSeconds": gap_seconds, "trend": "unknown"}

        # Compare the current reading against the average of everything
        # before it in the window, which smooths out single-sample OCR
        # noise on the gap digits while still being responsive to a
        # genuine, sustained closing/losing trend within ~1 second
        # (5 samples at 5Hz).
        baseline = sum(history[:-1]) / len(history[:-1])
        delta = gap_seconds - baseline

        if delta <= -self._min_change_seconds:
            trend = "closing"
        elif delta >= self._min_change_seconds:
            trend = "losing"
        else:
            trend = "steady"

        return {"gapSeconds": gap_seconds, "trend": trend}


def main() -> None:
    parser = argparse.ArgumentParser(description="Boxbox laptop HUD OCR relay")
    parser.add_argument("--capture-index", type=int, default=0)
    parser.add_argument(
        "--device-ip",
        "--phone-ip",
        dest="device_ip",
        type=str,
        required=False,
        help="Local network IP of the iPhone or iPad running Boxbox.",
    )
    parser.add_argument(
        "--roi-width-pct",
        type=float,
        default=0.20,
        help="DEPRECATED/unused -- the leaderboard crop is now a strict, "
        "hand-measured bounding box (see LEADERBOARD_X_MIN/MAX/Y_MIN/MAX "
        "in crop_roi), not a percentage-of-frame-width region. Kept only "
        "so existing scripts passing this flag don't break.",
    )
    parser.add_argument(
        "--sample-hz",
        type=float,
        default=8.0,
        help="OCR sampling rate. Higher = faster driverAhead/driverBehind "
        "updates on overtakes, at the cost of more CPU load per second. "
        "Each --name-stability confirmation takes --sample-hz samples to "
        "resolve, so e.g. 8Hz with stability=2 confirms a name change in "
        "~250ms instead of 5Hz/stability=3's ~600ms.",
    )
    parser.add_argument(
        "--name-stability",
        type=int,
        default=2,
        help="Number of consecutive samples a genuinely different "
        "driverAhead/driverBehind name must be read before it's accepted "
        "(filters out a single noisy OCR misread). Lower = faster "
        "response to real overtakes, higher = more resistant to flicker.",
    )
    parser.add_argument(
        "--position-stability",
        type=int,
        default=3,
        help="Number of consecutive samples a genuinely different "
        "gridPosition must be read before it's accepted (filters out "
        "single-frame OCR noise, e.g. the highlighted-row detector "
        "mis-firing or a row dropping out of the y-proximity grouping, "
        "that would otherwise flicker the displayed position between "
        "two values while actually holding station). Higher than "
        "--name-stability's default since gridPosition has no natural "
        "substring/partial-match leniency the way driver names do.",
    )
    parser.add_argument("--list-devices", action="store_true")
    parser.add_argument(
        "--debug",
        action="store_true",
        help="Print the raw OCR rows read each frame your own driver row "
        "can't be matched (gridPosition stuck at 0) -- helps diagnose "
        "whether the capture ROI, driver name match, or OCR itself is "
        "the problem.",
    )
    parser.add_argument(
        "--save-frame",
        type=str,
        default=None,
        help="Save a single cropped ROI frame to this path and exit "
        "immediately, for visually inspecting exactly what the capture "
        "card + ROI crop are feeding into OCR (e.g. to confirm what a "
        "misread HUD value actually looks like).",
    )
    parser.add_argument(
        "--driver-name",
        type=str,
        required=False,
        help="Your exact GT7 PSN display name, used to find your row in the "
        "on-screen leaderboard so driver-ahead/driver-behind can be "
        "extracted relative to your actual position. Required unless "
        "using --list-devices.",
    )
    args = parser.parse_args()

    if args.list_devices:
        list_devices()
        return

    if not args.device_ip:
        raise SystemExit("--device-ip is required unless using --list-devices")
    if not args.driver_name:
        raise SystemExit("--driver-name is required unless using --list-devices")

    capture = cv2.VideoCapture(args.capture_index)
    if not capture.isOpened():
        raise SystemExit(f"Could not open capture device at index {args.capture_index}")

    if args.save_frame:
        ok, frame = capture.read()
        if not ok:
            raise SystemExit("Could not read a frame from the capture device.")
        roi = crop_roi(frame, args.roi_width_pct)
        cv2.imwrite(args.save_frame, roi)
        print(f"Saved cropped ROI frame to {args.save_frame}")
        capture.release()
        return

    # EasyOCR's gpu=True maps to CUDA on most platforms, but on Apple
    # Silicon PyTorch instead routes it through MPS, which has had
    # long-standing compatibility hangs with some EasyOCR/torchvision ops
    # (observed here as the model "downloading"/initializing step
    # appearing to hang indefinitely at a fixed progress percentage while
    # still consuming CPU). CPU-only is slower per-frame but reliable; it
    # has kept up with --sample-hz in practice against a real race, but
    # if CPU usage/latency becomes a problem on a slower machine, lower
    # --sample-hz back down (the loop is synchronous: capture -> OCR ->
    # send, so an OCR pass slower than the sample interval will just
    # throttle the effective rate rather than falling behind/queuing).
    reader = easyocr.Reader(["en"], gpu=False)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    stabilizer = NameStabilizer(stability_threshold=args.name_stability)
    position_stabilizer = GridPositionStabilizer(stability_threshold=args.position_stability)
    gap_tracker = GapTracker()

    sample_interval = 1.0 / args.sample_hz
    last_sample_time = 0.0

    print(f"Streaming parsed leaderboard data to {args.device_ip}:{UDP_PORT} "
          f"at {args.sample_hz}Hz. Press Ctrl+C to stop.")

    try:
        while True:
            ok, frame = capture.read()
            if not ok:
                continue

            now = time.time()
            if now - last_sample_time < sample_interval:
                continue
            last_sample_time = now

            roi = crop_roi(frame, args.roi_width_pct)
            # detail=1 returns (bbox, text, confidence) tuples -- needed
            # to group fragments into rows by y-position and find the
            # driver's own row, rather than guessing based on line order.
            results = reader.readtext(roi, detail=1, paragraph=False)
            parsed = parse_leaderboard(
                results,
                args.driver_name,
                frame_bgr=roi,
                roi_width=roi.shape[1],
                roi_height=roi.shape[0],
                debug=args.debug,
                # Supplementary preprocessed+digit-only re-read for any
                # row whose position number the initial single-pass OCR
                # dropped entirely -- see reread_position_column.
                position_reread_fn=lambda row_items: reread_position_column(
                    reader, roi, row_items, roi.shape[1]
                ),
            )

            parsed["driverAhead"] = stabilizer.update("ahead", parsed["driverAhead"])
            parsed["driverBehind"] = stabilizer.update("behind", parsed["driverBehind"])
            parsed["gridPosition"] = position_stabilizer.update(parsed["gridPosition"]) or 0

            ahead_gap = gap_tracker.update("ahead", parsed.pop("gapAheadSeconds"))
            behind_gap = gap_tracker.update("behind", parsed.pop("gapBehindSeconds"))
            leader_gap = gap_tracker.update("leader", parsed.pop("gapToLeaderSeconds"))
            parsed["gapAheadSeconds"] = ahead_gap["gapSeconds"]
            parsed["gapAheadTrend"] = ahead_gap["trend"]
            parsed["gapBehindSeconds"] = behind_gap["gapSeconds"]
            parsed["gapBehindTrend"] = behind_gap["trend"]
            parsed["gapToLeaderSeconds"] = leader_gap["gapSeconds"]
            parsed["gapToLeaderTrend"] = leader_gap["trend"]

            payload = json.dumps(parsed).encode("utf-8")
            sock.sendto(payload, (args.device_ip, UDP_PORT))
            print(parsed)
    except KeyboardInterrupt:
        print("Stopping OCR relay.")
    finally:
        capture.release()
        sock.close()


if __name__ == "__main__":
    main()
