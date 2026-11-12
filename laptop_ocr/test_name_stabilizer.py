#!/usr/bin/env python3
"""Standalone validation for NameStabilizer: simulates the exact flicker
pattern observed live ("G. Howe" <-> "Howe"), and a genuine standings
change, to confirm the smoothing logic behaves correctly."""
from ocr_relay import NameStabilizer


def check(label, condition):
    print(f"{'PASS' if condition else 'FAIL'} {label}")
    if not condition:
        raise SystemExit(1)


stabilizer = NameStabilizer(stability_threshold=3)

# Simulate the real observed flicker: full name, then dropped initial,
# repeatedly -- should stay stable at the longest/most-complete reading.
sequence = ["G. Howe", "Howe", "G. Howe", "Howe", "Howe", "G. Howe"]
results = [stabilizer.update("ahead", name) for name in sequence]
check("flicker stays stable at full name", all(r == "G. Howe" for r in results))

# Simulate a genuine standings change: a different driver overtakes,
# consistently read the same way for several samples in a row.
stabilizer2 = NameStabilizer(stability_threshold=3)
stabilizer2.update("ahead", "G. Howe")
stabilizer2.update("ahead", "G. Howe")
r1 = stabilizer2.update("ahead", "P. Pereira")
r2 = stabilizer2.update("ahead", "P. Pereira")
r3 = stabilizer2.update("ahead", "P. Pereira")
check("single different read doesn't immediately flip", r1 == "G. Howe")
check("still old name on second consistent different read", r2 == "G. Howe")
check("flips to new name once stable for threshold samples", r3 == "P. Pereira")

# Bug repro: dropping to last place means driverBehind is genuinely
# None from here on (no car behind). Previously the stabilizer treated
# any None reading as "no update, keep stale value" forever, so the
# last car's name stuck around even once you were permanently last --
# producing the reported bug where "ahead" and "behind" showed the same
# name. A None reading should behave like any other different reading:
# ignored at first (protects against a single transient OCR miss
# mid-race), then accepted once consistently read for a few samples.
stabilizer3 = NameStabilizer(stability_threshold=3)
stabilizer3.update("behind", "H. Leblanc")
stabilizer3.update("behind", "H. Leblanc")
r1 = stabilizer3.update("behind", None)
r2 = stabilizer3.update("behind", None)
r3 = stabilizer3.update("behind", None)
check("single missing read doesn't immediately clear (transient OCR miss)", r1 == "H. Leblanc")
check("still old name on second consistent missing read", r2 == "H. Leblanc")
check("clears to None once missing has been stable for threshold samples (genuine last place)", r3 is None)

# Once cleared to None, a real name reappearing (e.g. a car genuinely
# catches up behind you again) is accepted immediately -- the same
# "first-ever reading" fast-path as app startup applies, since there's
# nothing stale on screen to protect against once we're confirmed-None.
r4 = stabilizer3.update("behind", "J. Dubois")
check("name reappearing after confirmed None is accepted immediately", r4 == "J. Dubois")

print("\nAll NameStabilizer checks passed.")
