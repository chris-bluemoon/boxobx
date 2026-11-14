#!/usr/bin/env python3
"""Validation for GT7's pit-lane "P" marker detection (row_has_pit_marker,
PitMarkerStabilizer, and parse_leaderboard's driversInPit output),
against two real replay captures:

- test_fixtures/pit_marker_frame.jpg: Daywalkar (P2) in the pit lane,
  with the white "P" box left of their position number.
- test_fixtures/no_pit_marker_frame.jpg: nobody in the pits (sky/trees
  behind the leaderboard's left edge).

Run with: python test_pit_marker.py
"""
import cv2

from ocr_relay import (
    PitMarkerStabilizer,
    crop_roi,
    leaderboard_y_offset,
    parse_leaderboard,
    read_pit_service,
    row_has_pit_marker,
)


def check(label, condition):
    print(f"{'PASS' if condition else 'FAIL'} {label}")
    if not condition:
        raise SystemExit(1)


pit_frame = cv2.imread("test_fixtures/pit_marker_frame.jpg")
clear_frame = cv2.imread("test_fixtures/no_pit_marker_frame.jpg")

# Row centres (full-frame y) measured off the captures.
check("the marker beside Daywalkar's row (y=233) is detected", row_has_pit_marker(pit_frame, 233))
for y in (192, 301, 369, 409, 449, 489, 529, 589):
    check(f"no marker detected beside the row at y={y} in the pit frame", not row_has_pit_marker(pit_frame, y))
for y in (193, 233, 261, 301, 341, 381, 421, 461, 501, 589):
    check(f"no marker detected at y={y} when nobody is pitting", not row_has_pit_marker(clear_frame, y))

# --- PitMarkerStabilizer: two consecutive samples before reporting. ---
stabilizer = PitMarkerStabilizer()
check("first sighting is not reported yet", stabilizer.update({"Daywalkar86": 2}) == {})
check("second consecutive sighting is reported", stabilizer.update({"Daywalkar86": 2}) == {"Daywalkar86": 2})
check("a missed sample drops it", stabilizer.update({}) == {})

check("and it needs two sightings again", stabilizer.update({"Daywalkar86": 2}) == {})

# --- End to end: real OCR + parse on the pit frame. ---
import easyocr  # noqa: E402  (slow import; only needed for this part)

reader = easyocr.Reader(["en"], gpu=False, verbose=False)
roi = crop_roi(pit_frame)
offset = leaderboard_y_offset(pit_frame)
parsed = parse_leaderboard(
    reader.readtext(roi, detail=1, paragraph=False),
    "Willy Swerve",
    frame_bgr=roi,
    roi_width=roi.shape[1],
    roi_height=roi.shape[0],
    header_position=3,
    pit_marker_fn=lambda row: row_has_pit_marker(pit_frame, offset + sum(y for _t, _x, y in row) / len(row)),
    pit_service_fn=lambda row: read_pit_service(reader, pit_frame, offset + sum(y for _t, _x, y in row) / len(row)),
)
check(
    "driversInPit reports Daywalkar (roster ID) and nobody else",
    list(parsed["driversInPit"]) == ["Daywalkar86"],
)
check(
    "Daywalkar's stop shows Soft tyres and 57 fuel, as on screen",
    # (position isn't checked: this test doesn't run the row-digit re-read)
    {k: parsed["driversInPit"]["Daywalkar86"][k] for k in ("tyre", "fuel")} == {"tyre": "S", "fuel": 57},
)
# Each compound colour, painted as a solid circle into the tyre slot of
# a copy of the real frame (over the captured red Soft circle).
for colour_bgr, expected in [
    ((40, 40, 230), "S"),
    ((40, 220, 240), "M"),
    ((245, 245, 245), "H"),
    ((60, 200, 60), "IM"),
    ((220, 120, 30), "W"),
]:
    painted = pit_frame.copy()
    cv2.circle(painted, (305, 233), 16, colour_bgr, -1)
    check(
        f"a {expected} compound circle is classified as {expected}",
        read_pit_service(reader, painted, 233)["tyre"] == expected,
    )

check(
    "a row with no pit box reads no tyre or fuel",
    read_pit_service(reader, clear_frame, 301) == {"tyre": None, "fuel": None},
)
check("the car ahead in the pits is still the car ahead", parsed["driverAhead"] == "Daywalkar86")

# --- Our own car in the pits (test_fixtures/own_pit_marker_frame.jpg:
# leading, P marker on our highlighted row, Softs, 17 fuel). ---
own_frame = cv2.imread("test_fixtures/own_pit_marker_frame.jpg")
check("our own row's marker (white highlighted row, y=193) is detected", row_has_pit_marker(own_frame, 193))
check("the row below ours is not flagged", not row_has_pit_marker(own_frame, 261))
own_roi = crop_roi(own_frame)
own_offset = leaderboard_y_offset(own_frame)
own_parsed = parse_leaderboard(
    reader.readtext(own_roi, detail=1, paragraph=False),
    "Willy Swerve",
    frame_bgr=own_roi,
    roi_width=own_roi.shape[1],
    roi_height=own_roi.shape[0],
    header_position=1,
    pit_marker_fn=lambda row: row_has_pit_marker(own_frame, own_offset + sum(y for _t, _x, y in row) / len(row)),
    pit_service_fn=lambda row: read_pit_service(reader, own_frame, own_offset + sum(y for _t, _x, y in row) / len(row)),
)
check("playerInPit is reported for our own car", own_parsed["playerInPit"] is True)
check("our own tyre and fuel are read", own_parsed["playerPitService"] == {"tyre": "S", "fuel": 17})
check("our own car is not listed among other drivers in the pits", own_parsed["driversInPit"] == {})
check("a frame without our marker reports playerInPit False", parsed["playerInPit"] is False)

print("\nAll pit marker checks passed.")
