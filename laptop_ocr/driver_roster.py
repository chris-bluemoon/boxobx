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

GT7 doesn't always show the PSN ID, though: replays (and some lobby
settings) show each driver's GT7 profile NICKNAME instead -- e.g.
"Willy Swerve" on screen for the roster's "Willy-SwerveX". Those are
too different for fuzzy matching to bridge, so NICKNAME_ALIASES maps
each known nickname to its PSN ID, and every match in this module goes
through it. Unknown nicknames still fail safe (pass through unchanged);
run the relay with --debug to see which on-screen names didn't match.

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

# On-screen GT7 nickname -> PSN ID from LEAGUE_ROSTER, for drivers
# whose nickname differs from their PSN ID (see module docstring). Only
# needed when the two are too different for fuzzy matching alone --
# add one line per driver as you spot them in a replay/lobby.
#
# Drivers whose nickname IS their PSN ID (LocoRx2, Morgsxr6) need no
# entry. Still unknown: warrenb313-wazza, Doogle_Dave, bennykezza.
NICKNAME_ALIASES = {
    "Willy Swerve": "Willy-SwerveX",
    # Shown in-game as "Casper_ _"; OCR usually drops the trailing
    # underscores and reads plain "Casper", so both forms are listed.
    "Casper_ _": "L0k1_317",
    "Casper": "L0k1_317",
    "Rycardo": "ryan_tr17",
    "Joey": "joeysnarf",
    "Black Sugar": "BlackSugar73",
    "Sushie_GT": "SushiSuzie",
    "Sideshow308": "sideshow-308",
    "Cam": "TCR_Camcorp",
    "Rooster": "Halfback66",
    "The Elder": "The_Elder",
    "Daywalkar": "Daywalkar86",
    "Salty67": "Salty-067",
    "ChuckE82": "Chuck_E82",
}

# How close (0.0-1.0, via difflib's SequenceMatcher ratio) an OCR'd name
# must be to a roster entry before it's confidently corrected -- high
# enough that two genuinely different short names (e.g. two different
# 5-letter gamertags) won't accidentally collapse into each other, but
# forgiving enough to catch a dropped/substituted character or two
# (the kind of single-character OCR noise observed live elsewhere in
# this codebase, e.g. "Wiily Swerve" for "Willy Swerve").
_MATCH_CONFIDENCE_THRESHOLD = 0.75


def _match_candidates(roster: list[str] | None) -> dict[str, str]:
    """Every text that should resolve to a roster ID: the IDs
    themselves, plus each nickname alias whose ID is in this roster."""
    ids = roster if roster is not None else LEAGUE_ROSTER
    candidates = {psn_id: psn_id for psn_id in ids}
    for nickname, psn_id in NICKNAME_ALIASES.items():
        if psn_id in candidates:
            candidates[nickname] = psn_id
    return candidates


def _closest_roster_id(ocr_name: str, roster: list[str] | None) -> str | None:
    import difflib

    candidates = _match_candidates(roster)
    matches = difflib.get_close_matches(ocr_name, list(candidates), n=1, cutoff=_MATCH_CONFIDENCE_THRESHOLD)
    return candidates[matches[0]] if matches else None


def is_close_to_roster_entry(ocr_name: str | None, roster: list[str] | None = None) -> bool:
    """True if ocr_name confidently matches a real roster entry or one
    of its known nicknames (same threshold as correct_driver_name) --
    used to EXEMPT a known-real name from ocr_relay.py's garbled-OCR-
    noise heuristics (e.g. MIXED_CASE_WITHIN_WORD_PATTERN) before those
    heuristics ever get a chance to reject it.

    Those heuristics were written assuming every real driver name is
    GT7's "<Initial>. <Surname>" display format (no internal capitals,
    e.g. "K. Nobori") -- a PSN gamertag like "Willy-SwerveX" or
    "TCR_Camcorp" has exactly the mixed-case shape those heuristics
    were built to reject as noise. The roster is a STRONGER, more
    direct signal than a shape-based heuristic ever could be.
    """
    if not ocr_name:
        return False
    return _closest_roster_id(ocr_name, roster) is not None


def correct_driver_name(ocr_name: str | None, roster: list[str] | None = None) -> str | None:
    """Returns the PSN ID of the closest roster entry -- matched by its
    PSN ID or by a known nickname (NICKNAME_ALIASES) -- if it's a
    confident match (ratio >= _MATCH_CONFIDENCE_THRESHOLD), otherwise
    returns ocr_name completely unchanged. This is a correction layer,
    not a filter: an unrecognized name (a guest driver, an unknown
    nickname, or a misread too garbled to resolve) is passed through
    as-is rather than dropped.

    roster defaults to LEAGUE_ROSTER but can be overridden (e.g. the
    relay's --rival-names list); nickname aliases apply to whichever
    roster is used.
    """
    if ocr_name is None:
        return None
    return _closest_roster_id(ocr_name, roster) or ocr_name


def is_same_driver(name_a: str | None, name_b: str | None) -> bool:
    """True if two names refer to the same driver: a loose substring
    match (OCR often drops a character), or both resolve to the same
    roster ID -- so "--driver-name Willy-SwerveX" still finds an
    on-screen "Willy Swerve" row, and vice versa."""
    if not name_a or not name_b:
        return False
    a, b = name_a.lower(), name_b.lower()
    if a in b or b in a:
        return True
    id_a = _closest_roster_id(name_a, None)
    return id_a is not None and id_a == _closest_roster_id(name_b, None)
