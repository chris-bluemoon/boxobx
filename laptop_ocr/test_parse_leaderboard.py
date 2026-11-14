#!/usr/bin/env python3
"""Standalone validation for parse_leaderboard against the REAL GT7
standings HUD layout, confirmed against real race screenshots during
development: a numbered list (position number, driver name, national
flag icon, optional gap-to-ahead rendered as its own standalone row
between two name rows), with the driver's own row visually highlighted
(much brighter + red-tinted vs other rows -- confirmed: highlighted row
measured ~132/125/153 BGR vs ~57-74/48-67/44-68 for everything else),
plus a separate large standalone "POSITION" digit tile used as a
fallback, and the driver's own row carrying an inline red gap-to-LEADER
number (a different quantity from gap-to-ahead) on the same line as
their name.
"""
import numpy as np

from ocr_relay import parse_leaderboard


def check(label, condition):
    print(f"{'PASS' if condition else 'FAIL'} {label}")
    if not condition:
        raise SystemExit(1)


def box(x, y, w=60, h=20):
    """A fake EasyOCR bbox: 4 corners of a w x h rectangle at (x, y)."""
    return [[x, y], [x + w, y], [x + w, y + h], [x, y + h]]


def row(y, *fragments):
    """fragments: list of (text, x) tuples rendered on the same row."""
    return [(box(x, y), text, 0.9) for text, x in fragments]


def fake_frame(height=450, width=384, highlighted_y_range=None):
    """A synthetic dark-HUD BGR frame, optionally with a brighter/
    red-tinted band in the given (y1, y2) range standing in for GT7's
    real highlighted-row colouring."""
    frame = np.full((height, width, 3), (60, 52, 48), dtype=np.uint8)
    if highlighted_y_range:
        y1, y2 = highlighted_y_range
        frame[y1:y2, :] = (132, 125, 153)
    return frame


# Real HUD layout: numbered standings list (1-5), driver's own row
# highlighted with an inline gap-to-leader, standalone gap-to-ahead rows
# between name rows, plus the separate POSITION header digit tile.
ocr_results = [
    *row(56, ("POSITION", 128), ("LAP", 295)),
    *row(80, ("2", 62)),
    *row(95, ("75", 128), ("1/3", 294)),  # a known OCR misread fragment nearby -- must not be used
    *row(193, ("1", 60), ("K. Wilson", 89)),
    *row(227, ("+9.453", 229)),  # Willy Swerve's gap to the car ahead (Wilson)
    *row(262, ("2", 60), ("Willy Swerve", 88), ("+4:15", 307)),  # inline = gap to LEADER
    *row(295, ("+0.225", 227)),  # D. Jung's gap to the car ahead (Willy Swerve)
    *row(329, ("3", 60), ("D. Jung", 108)),
    *row(369, ("4", 60), ("G. De Simone", 93)),
    *row(409, ("5", 60), ("K. Nobori", 89)),
]
frame = fake_frame(highlighted_y_range=(255, 280))

result = parse_leaderboard(ocr_results, driver_name="Willy Swerve", frame_bgr=frame, roi_width=frame.shape[1])
check("gridPosition read from the matched row's own position number", result["gridPosition"] == 2)
check("driverAhead is the name on the row above (position 1)", result["driverAhead"] == "K. Wilson")
check("driverBehind is the name on the row below (position 3)", result["driverBehind"] == "D. Jung")
check(
    "gapAheadSeconds is OUR gap to the car ahead (own standalone gap row)",
    abs(result["gapAheadSeconds"] - 9.453) < 0.01,
)
check(
    "gapBehindSeconds is the car behind's gap to US (their standalone gap row)",
    abs(result["gapBehindSeconds"] - 0.225) < 0.01,
)
check(
    "gapToLeaderSeconds is OUR inline red gap number, not gap-to-ahead",
    abs(result["gapToLeaderSeconds"] - 255) < 1,  # 4:15 == 255 seconds
)


# Without a highlighted row (frame_bgr not supplied), falls back to
# name matching and still resolves gaps/names correctly.
result_no_frame = parse_leaderboard(ocr_results, driver_name="Willy Swerve")
check(
    "falls back to name matching when no frame is supplied",
    result_no_frame["driverAhead"] == "K. Wilson" and result_no_frame["driverBehind"] == "D. Jung",
)


# Bug repro (still relevant): a car's class/model label (e.g. "F1 GT")
# on the same line as the driver name should be stripped from the name.
ocr_results_2 = [
    *row(56, ("POSITION", 128)),
    *row(80, ("19", 62)),
    *row(193, ("19", 60), ("P Pereira", 90), ("F1 GT", 220)),
    *row(223, ("20", 60), ("Willy Swerve", 90), ("Gr.3", 220)),
]
result2 = parse_leaderboard(ocr_results_2, driver_name="Willy Swerve")
check(
    "car class label stripped from driverAhead name (also normalized to 'P. Pereira')",
    result2["driverAhead"] == "P. Pereira",
)
check("gridPosition still read correctly alongside a car-class-label row", result2["gridPosition"] == 20)
check("driverBehind is None with no entry below", result2["driverBehind"] is None)


# Bug repro: a sponsor billboard/track-side all-caps text fragment well
# below the standings list (e.g. "POLYPHC" from a "POLYPHONY DIGITAL"
# billboard) must not be misread as driverBehind when the driver is
# genuinely in last place with no real row below them.
ocr_results_3 = [
    *row(56, ("POSITION", 128)),
    *row(80, ("5", 62)),
    *row(193, ("1", 60), ("K. Wilson", 89)),
    *row(233, ("D: Jung", 88)),
    *row(273, ("De Simone", 115)),
    *row(313, ("K. Nobori", 91)),
    *row(347, ("+23.716", 211)),
    *row(382, ("Willy Swerve", 88), ("+43.718", 289)),
    *row(562, ("POLYPHC", 289)),
]
frame3 = fake_frame(height=1100, highlighted_y_range=(370, 395))
result3 = parse_leaderboard(ocr_results_3, driver_name="Willy Swerve", frame_bgr=frame3, roi_width=frame3.shape[1])
check(
    "sponsor billboard text is not mistaken for driverBehind when actually in last place",
    result3["driverBehind"] is None,
)
check("driverAhead still resolves correctly despite the billboard junk row", result3["driverAhead"] == "K. Nobori")


# Bug repro: a non-highlighted row that happens to be a bit brighter
# than usual (but nowhere near the genuinely highlighted row's
# brightness/colour jump) must not be falsely detected as the driver's
# own row.
ocr_results_4 = [
    *row(56, ("POSITION", 128)),
    *row(80, ("4", 62)),
    *row(193, ("1", 60), ("K. Wilson", 89)),
    *row(233, ("2", 60), ("D. Jung", 88)),
    *row(273, ("3", 60), ("G. De Simone", 93)),
    *row(313, ("4", 60), ("Willy Swerve", 91), ("+2:10", 300)),
    *row(347, ("+3:49", 237)),
    *row(382, ("5", 60), ("K. Nobori", 91)),
]
frame4 = fake_frame(highlighted_y_range=(305, 330))
frame4[260:290, :] = (74, 67, 68)  # a brighter-than-average but NOT highlighted row
result4 = parse_leaderboard(ocr_results_4, driver_name="Willy Swerve", frame_bgr=frame4, roi_width=frame4.shape[1])
check(
    "a merely-brighter-than-average row is not falsely detected as the highlighted own row",
    result4["driverAhead"] == "G. De Simone" and result4["driverBehind"] == "K. Nobori",
)

# Bug repro: a comma-separated lap-timer fragment (e.g. "19,07,333")
# well below the standings list must not be misread as driverBehind.
ocr_results_5 = [
    *row(56, ("POSITION", 128)),
    *row(80, ("5", 62)),
    *row(193, ("1", 60), ("K. Wilson", 89)),
    *row(233, ("2", 60), ("D. Jung", 88)),
    *row(273, ("3", 60), ("G. De Simone", 93)),
    *row(313, ("4", 60), ("K. Nobori", 91)),
    *row(347, ("+23.716", 211)),
    *row(382, ("5", 60), ("Willy Swerve", 88), ("+4:15", 289)),
    *row(1037, ("19,07,333", 52)),
]
frame5 = fake_frame(height=1100, highlighted_y_range=(370, 395))
result5 = parse_leaderboard(ocr_results_5, driver_name="Willy Swerve", frame_bgr=frame5, roi_width=frame5.shape[1])
check(
    "comma-separated lap-timer text is not mistaken for driverBehind when actually in last place",
    result5["driverBehind"] is None,
)

# Bug repro: EasyOCR occasionally drops the "POSITION"/"LAP" words and
# reads only the leftover digits/brackets from the header (e.g.
# "[ 5 1/3"), which doesn't contain a HEADER_KEYWORDS word -- without a
# y-bound excluding the header region, this slips in as a phantom extra
# "driver" above everyone else, shifting every real position down by
# one. This was the actual root cause of positions flickering live
# during a race.
ocr_results_6 = [
    *row(56, ("POSITION", 128)),
    *row(80, ("[ 5 1/3", 62)),  # phantom garbled header fragment, same shape as a name row
    *row(193, ("1", 60), ("K. Wilson", 89)),
    *row(233, ("2", 60), ("D. Jung", 88)),
    *row(273, ("3", 60), ("G. De Simone", 93)),
    *row(313, ("4", 60), ("K. Nobori", 91)),
    *row(347, ("+45.423", 211)),
    *row(382, ("5", 60), ("Willy Swerve", 88), ("+53.718", 289)),
]
frame6 = fake_frame(highlighted_y_range=(370, 395))
result6 = parse_leaderboard(ocr_results_6, driver_name="Willy Swerve", frame_bgr=frame6, roi_width=frame6.shape[1])
check(
    "garbled header fragment does not shift gridPosition by one (phantom row bug)",
    result6["gridPosition"] == 5,
)
check(
    "garbled header fragment does not get treated as driverAhead",
    result6["driverAhead"] == "K. Nobori",
)

# Bug repro: the same real driver's name renders inconsistently across
# frames depending on whether OCR catches the period after the initial
# (observed live: "K. Nobori" vs "K Nobori" vs "K: Nobori") -- all
# variants must resolve to the exact same canonical string so the name
# displayed on the dashboard doesn't visibly flicker between forms.
ocr_results_7 = [
    *row(56, ("POSITION", 128)),
    *row(80, ("5", 62)),
    *row(193, ("1", 60), ("K. Wilson", 89)),
    *row(233, ("2", 60), ("D. Jung", 88)),
    *row(273, ("3", 60), ("G. De Simone", 93)),
    *row(313, ("4", 60), ("K Nobori", 89)),  # period dropped by OCR this frame
    *row(382, ("5", 60), ("Willy Swerve", 88)),
]
result7 = parse_leaderboard(ocr_results_7, driver_name="Willy Swerve")
check(
    "name missing its period is normalized to the canonical 'K. Nobori' form",
    result7["driverAhead"] == "K. Nobori",
)

ocr_results_8 = [
    *row(56, ("POSITION", 128)),
    *row(80, ("5", 62)),
    *row(193, ("1", 60), ("K. Wilson", 89)),
    *row(233, ("2", 60), ("D. Jung", 88)),
    *row(273, ("3", 60), ("G. De Simone", 93)),
    *row(313, ("4", 60), ("K: Nobori", 89)),  # period misread as a colon this frame
    *row(382, ("5", 60), ("Willy Swerve", 88)),
]
result8 = parse_leaderboard(ocr_results_8, driver_name="Willy Swerve")
check(
    "name with period misread as colon is normalized to the same canonical 'K. Nobori' form",
    result8["driverAhead"] == "K. Nobori",
)
check(
    "both OCR variants of the same name normalize identically (no flicker)",
    result7["driverAhead"] == result8["driverAhead"],
)

# Own name ("Willy Swerve") and names missing an initial entirely
# ("De Simone") must NOT be mangled by the normalization.
from ocr_relay import _normalize_driver_name  # noqa: E402

check("two-word first name is left untouched", _normalize_driver_name("Willy Swerve") == "Willy Swerve")
check("name missing its initial entirely is left untouched", _normalize_driver_name("De Simone") == "De Simone")


# Bug repro: a garbled OCR misread of a gap/time value (observed live:
# "HoOOn", standing in for driverBehind) must not be treated as a real
# driver name just because it sat alone on its row and didn't parse as
# a clean gap value.
ocr_results_9 = [
    *row(56, ("POSITION", 128)),
    *row(80, ("5", 62)),
    *row(193, ("1", 60), ("K. Wilson", 89)),
    *row(233, ("2", 60), ("D. Jung", 88)),
    *row(273, ("3", 60), ("G. De Simone", 93)),
    *row(313, ("4", 60), ("K. Nobori", 91)),
    *row(347, ("+55.151", 211)),
    *row(382, ("5", 60), ("Willy Swerve", 88), ("+57.045", 289)),
    *row(417, ("HoOOn", 88)),  # garbled OCR noise where a real row-6 entry (if any) would be
]
result9 = parse_leaderboard(ocr_results_9, driver_name="Willy Swerve")
check(
    "garbled mixed-case OCR noise is not treated as a real driverBehind name",
    result9["driverBehind"] is None,
)

# Bug repro: GT7's in-race leaderboard is frequently NOT a contiguous
# P1-downward list -- confirmed live, it shows the top few cars (e.g.
# P2-P3) plus a separate sliding window around the driver's own car
# (e.g. P8-P12), with no rows at all for the positions skipped over.
# own_index + 1 ("this row's rank among the rows visible this frame")
# used to be used as a fallback when a row's own position digit wasn't
# read -- here Willy Swerve's own row DOES carry its real digit (12),
# so gridPosition must come from that, not from own_index + 1 (which
# would incorrectly compute 7, since this is the 7th row in the list).
ocr_results_10 = [
    *row(56, ("POSITION", 128)),
    *row(80, ("12", 62)),
    *row(100, ("2", 60), ("L. Joseph", 88)),
    *row(135, ("3", 60), ("D. Preston", 88)),
    *row(230, ("8", 60), ("F. Schmidt", 88)),
    *row(265, ("9", 60), ("M. Hendriks", 88)),
    *row(300, ("10", 60), ("E. Vos", 88)),
    *row(335, ("11", 60), ("P. Lopez", 88)),
    *row(370, ("12", 60), ("Willy Swerve", 88), ("+1:09", 289)),
]
frame10 = fake_frame(highlighted_y_range=(360, 385))
result10 = parse_leaderboard(
    ocr_results_10, driver_name="Willy Swerve", frame_bgr=frame10, roi_width=frame10.shape[1]
)
check(
    "gridPosition reads the row's own digit (12), not its rank among visible rows (would be 7)",
    result10["gridPosition"] == 12,
)

# Roster correction: a confidently-read but slightly-garbled OCR name
# that's close to a REAL league roster entry gets corrected to that
# exact entry -- confirms parse_leaderboard actually applies
# driver_roster.correct_driver_name() to both driverAhead/driverBehind,
# not just that the module exists in isolation (see
# test_driver_roster.py for the correction logic's own unit tests).
ocr_results_11 = [
    *row(56, ("POSITION", 128)),
    *row(80, ("5", 62)),
    *row(193, ("1", 60), ("K. Wilson", 89)),
    *row(233, ("2", 60), ("G. De Simone", 93)),
    *row(273, ("3", 60), ("Chuck_E8", 89)),  # misread of a real roster entry, directly ahead
    *row(382, ("4", 60), ("Willy Swerve", 88)),
]
result11 = parse_leaderboard(ocr_results_11, driver_name="Willy Swerve")
check(
    "driverAhead's garbled-but-close roster name is corrected to the exact real entry",
    result11["driverAhead"] == "Chuck_E82",
)

ocr_results_12 = [
    *row(56, ("POSITION", 128)),
    *row(80, ("5", 62)),
    *row(193, ("1", 60), ("K. Wilson", 89)),
    *row(233, ("2", 60), ("A. Guest", 88)),  # directly ahead -- a plausible but non-roster name
    *row(382, ("3", 60), ("Willy Swerve", 88)),
]
result12 = parse_leaderboard(ocr_results_12, driver_name="Willy Swerve")
check(
    "a plausible name with no close roster match passes through completely unchanged (fails safe)",
    result12["driverAhead"] == "A. Guest",
)


# standings: every parsed row, not just driverAhead/driverBehind, is
# returned top to bottom -- so the app can follow its race rival even
# several rows away from the driver's own row.
ocr_results_13 = [
    *row(56, ("POSITION", 128)),
    *row(80, ("12", 62)),
    *row(100, ("2", 60), ("L. Joseph", 88)),
    *row(135, ("3", 60), ("Chuck_E82", 88)),  # NOT adjacent to the driver's own row
    *row(230, ("8", 60), ("F. Schmidt", 88)),
    *row(370, ("12", 60), ("Willy Swerve", 88)),
]
frame13 = fake_frame(highlighted_y_range=(360, 385))
result13 = parse_leaderboard(ocr_results_13, driver_name="Willy Swerve", frame_bgr=frame13, roi_width=frame13.shape[1])
standings13 = result13["standings"]
check(
    "every visible row is in standings, top to bottom, with its position",
    [(r["name"], r["position"]) for r in standings13]
    == [("L. Joseph", 2), ("Chuck_E82", 3), ("F. Schmidt", 8), ("Willy-SwerveX", 12)],
)
check(
    "only the driver's own row is flagged isPlayer",
    [r["isPlayer"] for r in standings13] == [False, False, False, True],
)

# A garbled-but-close reading of a roster name is corrected, same as
# driverAhead/driverBehind.
ocr_results_15 = [
    *row(56, ("POSITION", 128)),
    *row(80, ("5", 62)),
    *row(193, ("1", 60), ("Chck_E82", 89)),  # misread of a real roster name
    *row(382, ("5", 60), ("Willy Swerve", 88)),
]
result15 = parse_leaderboard(ocr_results_15, driver_name="Willy Swerve")
check(
    "a garbled roster name is corrected in standings",
    result15["standings"][0]["name"] == "Chuck_E82" and result15["standings"][0]["position"] == 1,
)

# Each row carries its own interval to the row above (the standalone gap
# row rendered between two names belongs to the LOWER one).
ocr_results_16 = [
    *row(56, ("POSITION", 128)),
    *row(80, ("4", 62)),
    *row(193, ("3", 60), ("Chuck_E82", 89)),
    *row(227, ("+1.420", 229)),
    *row(262, ("4", 60), ("Willy Swerve", 88)),
    *row(295, ("+0.850", 227)),
    *row(330, ("5", 60), ("SushiSuzie", 88)),
]
result16 = parse_leaderboard(ocr_results_16, driver_name="Willy Swerve")
check(
    "standings rows carry their own gap to the row above",
    [r["gapToAhead"] for r in result16["standings"]] == [None, 1.42, 0.85],
)


# Replays show GT7 profile NICKNAMES instead of PSN IDs. A known
# nickname (driver_roster.NICKNAME_ALIASES) must resolve to its PSN ID
# everywhere: driverAhead/driverBehind, standings, own-row
# lookup, and the mixed-case noise filter's roster exemption.
ocr_results_17 = [
    *row(56, ("POSITION", 128)),
    *row(80, ("6", 62)),
    *row(193, ("4", 60), ("Willy Swerve", 89)),  # nickname of roster's Willy-SwerveX
    *row(382, ("5", 60), ("Chuck_E82", 88)),
]
result17 = parse_leaderboard(ocr_results_17, driver_name="Chuck_E82")
check("a known nickname directly ahead resolves to its PSN ID", result17["driverAhead"] == "Willy-SwerveX")
check("a driver shown by nickname is listed in standings by PSN ID", result17["standings"][0]["name"] == "Willy-SwerveX")
check("own row found from the name match, giving the right position", result17["gridPosition"] == 5)

# --driver-name given as the PSN ID still finds the on-screen nickname
# row, and that row is flagged as the player's in standings.
ocr_results_18 = [
    *row(56, ("POSITION", 128)),
    *row(80, ("6", 62)),
    *row(193, ("2", 60), ("Chuck_E82", 89)),
    *row(382, ("3", 60), ("Willy Swerve", 88)),
]
result18 = parse_leaderboard(ocr_results_18, driver_name="Willy-SwerveX")
check("PSN-ID --driver-name matches the on-screen nickname row", result18["gridPosition"] == 3)
check("driverAhead is found relative to the nickname row", result18["driverAhead"] == "Chuck_E82")
check("own nickname row is flagged isPlayer", [r["isPlayer"] for r in result18["standings"]] == [False, True])


# A header tile reading supplied by the live loop (read_header_position)
# beats the own row's small position digit, and is still reported when
# the own row can't be found at all.
ocr_results_19 = [
    *row(193, ("1", 60), ("Willy Swerve", 89)),
    *row(261, ("2", 60), ("LocoRx2", 88)),
]
result19 = parse_leaderboard(ocr_results_19, driver_name="Willy Swerve", header_position=1)
check("header tile position is used for the own row", result19["gridPosition"] == 1)
check("the leader has nobody ahead", result19["driverAhead"] is None)
check("the car behind the leader is found", result19["driverBehind"] == "LocoRx2")
result19b = parse_leaderboard(
    [*row(193, ("4", 60), ("Willy Swerve", 89))], driver_name="Willy Swerve", header_position=3
)
check("header tile wins over a disagreeing row digit", result19b["gridPosition"] == 3)
result19c = parse_leaderboard([*row(261, ("2", 60), ("LocoRx2", 88))], driver_name="Willy Swerve", header_position=7)
check("header tile position is reported even when the own row is not found", result19c["gridPosition"] == 7)
result19d = parse_leaderboard([*row(193, ("4", 60), ("Willy Swerve", 89))], driver_name="Willy Swerve", header_position=0)
check("an unreadable header tile (0) falls back to the row digit", result19d["gridPosition"] == 4)

# driversInPit: rows the pit_marker_fn flags, roster-corrected, never
# the driver's own car, and an empty dict when nobody is in the pits.
ocr_results_20 = [
    *row(193, ("1", 60), ("LocoRx2", 89)),
    *row(233, ("2", 60), ("Daywalkar", 88)),
    *row(301, ("3", 60), ("Willy Swerve", 88)),
]
result20 = parse_leaderboard(
    ocr_results_20, driver_name="Willy Swerve", pit_marker_fn=lambda r: any(t in ("Daywalkar", "Willy Swerve") for t, _x, _y in r)
)
check(
    "a flagged row is reported in driversInPit by roster ID",
    result20["driversInPit"] == {"Daywalkar86": {"position": 2, "tyre": None, "fuel": None}},
)
result20c = parse_leaderboard(
    ocr_results_20,
    driver_name="Willy Swerve",
    pit_marker_fn=lambda r: any(t == "Daywalkar" for t, _x, _y in r),
    pit_service_fn=lambda r: {"tyre": "S", "fuel": 57},
)
check(
    "tyre and fuel from pit_service_fn are attached to the pitting driver",
    result20c["driversInPit"] == {"Daywalkar86": {"position": 2, "tyre": "S", "fuel": 57}},
)
result20b = parse_leaderboard(ocr_results_20, driver_name="Willy Swerve")
check("driversInPit is an empty dict without a pit_marker_fn", result20b["driversInPit"] == {})

print("\nAll parse_leaderboard checks passed.")
