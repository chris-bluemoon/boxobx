"""
Boxbox League Driver Roster

A hardcoded, known-good list of every driver's exact in-game display
name for a fixed league (Apex Point Racing League, GT3 Clubman
Division, per the weekly Discord standings report) -- used to CORRECT
OCR misreads of driverAhead/driverBehind, rather than accepting
whatever EasyOCR happened to read verbatim.

Why this helps: ocr_relay.py's existing NameStabilizer only smooths
FLICKER across consecutive frames (e.g. "G. Howe" one frame, "Howe"
the next) -- it has no way to know that a confidently-read, STABLE
name like "P Pereira" is actually a misread of a real roster entry,
since it never had anything to compare against. With a known, fixed
roster, a misread name can be corrected to its closest real match
rather than displayed wrong for the rest of the race.

IMPORTANT PRECONDITION: this only works if GT7 is configured to show
PSN online IDs in-race (Settings > ... network/display name option),
since the names below are exactly what the league's weekly standings
report shows (PSN gamertags like "Willy-SwerveX", "Chuck_E82") -- NOT
GT7's other possible display format ("<Initial>. <Surname>", e.g.
"K. Nobori"). If GT7 is showing a different name format than this
roster, correct_driver_name() will simply never find a confident match
and every name passes through unchanged (same as if this module didn't
exist at all) -- it fails safe, not by corrupting a name.

Update this list whenever the league roster changes (new driver joins,
existing driver changes PSN name, etc.) -- there is deliberately no
separate config file/database for this given how infrequently a GT3
Clubman Division's grid actually changes week to week.
"""
from __future__ import annotations

# Exact PSN gamertags from the Apex Point Racing League GT3 Clubman
# Division championship standings (confirmed against the weekly
# Discord report) -- update this list if/when the roster changes.
LEAGUE_ROSTER = [
    "Salty-067",
    "Chuck_E82",
    "Willy-SwerveX",
    "sideshow-308",
    "warrenb313-wazza",
    "ryan_tr17",
    "BlackSugar73",
    "SushiSuzie",
    "Daywalkar86",
    "Doogle_Dave",
    "L0k1_317",
    "Morgsxr6",
    "The_Elder",
    "Halfback66",
    "TCR_Camcorp",
    "joeysnarf",
    "LocoRx2",
    "bennykezza",
]

# How close (0.0-1.0, via difflib's SequenceMatcher ratio) an OCR'd name
# must be to a roster entry before it's confidently corrected -- high
# enough that two genuinely different short names (e.g. two different
# 5-letter gamertags) won't accidentally collapse into each other, but
# forgiving enough to catch a dropped/substituted character or two
# (the kind of single-character OCR noise observed live elsewhere in
# this codebase, e.g. "Wiily Swerve" for "Willy Swerve").
_MATCH_CONFIDENCE_THRESHOLD = 0.75


def is_close_to_roster_entry(ocr_name: str | None, roster: list[str] | None = None) -> bool:
    """True if ocr_name confidently matches a real roster entry (same
    threshold as correct_driver_name) -- used to EXEMPT a known-real
    PSN gamertag from ocr_relay.py's garbled-OCR-noise heuristics
    (e.g. MIXED_CASE_WITHIN_WORD_PATTERN) before those heuristics ever
    get a chance to reject it.

    Those heuristics were written assuming every real driver name is
    GT7's "<Initial>. <Surname>" display format (no internal capitals,
    e.g. "K. Nobori") -- a PSN gamertag like "Willy-SwerveX" or
    "TCR_Camcorp" has exactly the lowercase-then-uppercase/mixed-case
    shape those heuristics were built to reject as noise, even though
    it's a completely genuine name once GT7 is configured to display
    PSN IDs instead. The roster is a STRONGER, more direct signal than
    a shape-based heuristic ever could be -- if the raw OCR text is
    close enough to a real roster entry, it's real, full stop, and
    none of the shape-based rejection rules should get a vote.
    """
    if not ocr_name:
        return False

    import difflib

    candidates = roster if roster is not None else LEAGUE_ROSTER
    return bool(difflib.get_close_matches(ocr_name, candidates, n=1, cutoff=_MATCH_CONFIDENCE_THRESHOLD))


def correct_driver_name(ocr_name: str | None, roster: list[str] | None = None) -> str | None:
    """Returns the closest roster entry to ocr_name if it's a confident
    match (ratio >= _MATCH_CONFIDENCE_THRESHOLD), otherwise returns
    ocr_name completely unchanged -- this is a correction layer, not a
    filter: an unrecognized name (a guest driver not in the league, or
    a misread too garbled to confidently resolve) is passed through
    as-is rather than dropped, since showing *something* is better than
    silently hiding a real driverAhead/driverBehind reading.

    roster defaults to LEAGUE_ROSTER but can be overridden (mainly for
    testing a smaller fixed list without depending on the real one).
    """
    if ocr_name is None:
        return None

    import difflib

    candidates = roster if roster is not None else LEAGUE_ROSTER
    matches = difflib.get_close_matches(ocr_name, candidates, n=1, cutoff=_MATCH_CONFIDENCE_THRESHOLD)
    return matches[0] if matches else ocr_name
