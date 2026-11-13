"""Unit tests for driver_roster.py -- run with:
    python3 -m pytest laptop_ocr/test_driver_roster.py -v
"""
from driver_roster import correct_driver_name, LEAGUE_ROSTER


def test_exact_match_returned_unchanged():
    assert correct_driver_name("Willy-SwerveX") == "Willy-SwerveX"


def test_close_misread_is_corrected_to_the_real_roster_entry():
    # A single dropped/substituted character, the kind of OCR noise
    # observed live elsewhere in ocr_relay.py (e.g. "Wiily Swerve" for
    # "Willy Swerve").
    assert correct_driver_name("Chuck_E8") == "Chuck_E82"
    assert correct_driver_name("Wllly-SwerveX") == "Willy-SwerveX"


def test_unrecognized_name_passes_through_unchanged_rather_than_forced_to_closest():
    # A genuinely different name (e.g. a guest driver not in the
    # league, or a reading too garbled to confidently resolve) must
    # NOT be silently coerced into whatever roster entry happens to be
    # closest -- it should fail safe and pass through as-is.
    assert correct_driver_name("XyzNotARealDriver999") == "XyzNotARealDriver999"


def test_none_input_returns_none():
    assert correct_driver_name(None) is None


def test_custom_roster_override_is_respected():
    small_roster = ["Alice", "Bob"]
    assert correct_driver_name("Alce", roster=small_roster) == "Alice"
    assert correct_driver_name("Willy-SwerveX", roster=small_roster) == "Willy-SwerveX"


def test_roster_has_no_duplicate_entries():
    assert len(LEAGUE_ROSTER) == len(set(LEAGUE_ROSTER))


def test_two_distinct_short_roster_names_do_not_accidentally_collapse():
    # Guards the confidence threshold itself: two genuinely different
    # roster entries must never match each other.
    for name in LEAGUE_ROSTER:
        others = [n for n in LEAGUE_ROSTER if n != name]
        assert correct_driver_name(name, roster=others) == name
