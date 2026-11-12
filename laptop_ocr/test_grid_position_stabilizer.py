#!/usr/bin/env python3
"""Standalone validation for GridPositionStabilizer: simulates the exact
flicker pattern reported live (holding P5 steady, but the single-frame
gridPosition computation alternating P5/P6 due to a highlighted-row
mis-detection or a row dropping out of the y-proximity grouping), and a
genuine position change (a real overtake), to confirm the smoothing
logic behaves correctly -- same approach as test_name_stabilizer.py."""
from ocr_relay import GridPositionStabilizer


def check(label, condition):
    print(f"{'PASS' if condition else 'FAIL'} {label}")
    if not condition:
        raise SystemExit(1)


stabilizer = GridPositionStabilizer(stability_threshold=3)

# Simulate the real observed flicker: holding P5, but a stray frame
# misreads P6 here and there -- should stay stable at P5 throughout.
sequence = [5, 5, 6, 5, 6, 5, 5]
results = [stabilizer.update(p) for p in sequence]
check("flicker stays stable at P5", all(r == 5 for r in results))

# Simulate a genuine overtake: a real, consistent position change read
# the same way for several samples in a row.
stabilizer2 = GridPositionStabilizer(stability_threshold=3)
stabilizer2.update(5)
stabilizer2.update(5)
r1 = stabilizer2.update(6)
r2 = stabilizer2.update(6)
r3 = stabilizer2.update(6)
check("single different read doesn't immediately flip", r1 == 5)
check("still old position on second consistent different read", r2 == 5)
check("flips to new position once stable for threshold samples", r3 == 6)

# A missing/zero reading (driver row not located this frame, e.g. a
# momentary OCR miss) should keep showing the last confirmed position
# rather than flickering to 0/None.
stabilizer3 = GridPositionStabilizer(stability_threshold=3)
stabilizer3.update(5)
r1 = stabilizer3.update(0)
r2 = stabilizer3.update(None)
check("zero reading doesn't clear the current position", r1 == 5)
check("None reading doesn't clear the current position", r2 == 5)

# First-ever reading is accepted immediately -- nothing stale on
# screen yet to protect against.
stabilizer4 = GridPositionStabilizer(stability_threshold=3)
r1 = stabilizer4.update(5)
check("first-ever reading accepted immediately", r1 == 5)

print("\nAll GridPositionStabilizer checks passed.")
