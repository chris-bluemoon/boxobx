#!/usr/bin/env python3
"""Standalone validation for _parse_gap_seconds and GapTracker: the real
metric this whole feature exists for (closing/losing the gap), as
opposed to just showing a rival's name the driver can already see."""
from ocr_relay import GapTracker, _parse_gap_seconds, NUMERIC_ONLY_PATTERN


def check(label, condition):
    print(f"{'PASS' if condition else 'FAIL'} {label}")
    if not condition:
        raise SystemExit(1)


# --- _parse_gap_seconds: real GT7 format is "+M:SS", not decimal seconds ---
check("parses '+ 1:51' as 111s", _parse_gap_seconds("+ 1:51") == 111)
check("parses '+2:00' as 120s", _parse_gap_seconds("+2:00") == 120)
check("parses decimal fallback '+0.452'", abs(_parse_gap_seconds("+0.452") - 0.452) < 1e-9)
check("parses '+ 0.299' (OCR space after the sign) as 0.299s", abs(_parse_gap_seconds("+ 0.299") - 0.299) < 1e-9)
check("driver name 'S: Baumann' is not a gap", _parse_gap_seconds("S: Baumann") is None)
check("driver name 'G. Howe' is not a gap", _parse_gap_seconds("G. Howe") is None)

# Real bug found live: the "Fastest Lap" row's lap time ("1:53.128")
# shares the same leading "M:SS" shape as a real gap ("+1:51"). Must NOT
# be misread as a ~113 second gap.
check("fastest-lap time '1:53.128' is not a gap", _parse_gap_seconds("1:53.128") is None)
check("fastest-lap time '42:16.432' is not a gap", _parse_gap_seconds("42:16.432") is None)

# Real bug found live: a stray numeric fragment like "10.066" (no sign,
# so _parse_gap_seconds doesn't catch it) was leaking into driverBehind
# as if it were a driver's name.
check("'10.066' is purely numeric", bool(NUMERIC_ONLY_PATTERN.match("10.066")))
check("'G. Howe' is not purely numeric", not NUMERIC_ONLY_PATTERN.match("G. Howe"))
check("'Willy Swerve' is not purely numeric", not NUMERIC_ONLY_PATTERN.match("Willy Swerve"))

# --- GapTracker: closing trend ---
tracker = GapTracker(window_size=5, min_change_seconds=0.3)
readings = [10.0, 9.5, 9.0, 8.4, 7.9]  # steadily shrinking gap
results = [tracker.update("ahead", r) for r in readings]
check("first reading is 'unknown' (not enough history)", results[0]["trend"] == "unknown")
check("sustained shrinking gap is detected as 'closing'", results[-1]["trend"] == "closing")

# --- GapTracker: losing trend ---
tracker2 = GapTracker(window_size=5, min_change_seconds=0.3)
readings2 = [2.0, 2.6, 3.1, 3.7, 4.3]  # steadily growing gap
results2 = [tracker2.update("behind", r) for r in readings2]
check("sustained growing gap is detected as 'losing'", results2[-1]["trend"] == "losing")

# --- GapTracker: steady (noise within threshold shouldn't trigger a trend) ---
tracker3 = GapTracker(window_size=5, min_change_seconds=0.3)
readings3 = [5.0, 5.05, 4.98, 5.02, 5.01]  # essentially flat, tiny OCR jitter
results3 = [tracker3.update("ahead", r) for r in readings3]
check("tiny noise doesn't register as closing/losing", results3[-1]["trend"] == "steady")

# --- GapTracker: missing reading doesn't corrupt the trend ---
tracker4 = GapTracker(window_size=5, min_change_seconds=0.3)
tracker4.update("ahead", 10.0)
tracker4.update("ahead", 9.0)
missing_result = tracker4.update("ahead", None)
check("missing reading reports 'unknown', not a false trend", missing_result["trend"] == "unknown")

print("\nAll GapTracker/_parse_gap_seconds checks passed.")
