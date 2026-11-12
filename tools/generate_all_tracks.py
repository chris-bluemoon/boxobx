#!/usr/bin/env python3
"""
Generates assets/config/all_tracks.json for the Boxbox app -- the FULL
list of GT7 track/layout name+length pairs (including reverse layouts
and short layouts that have no surveyed/captured racing-line path),
used only by the Race Strategy screen's track-name dropdown.

This is deliberately separate from assets/config/tracks_db.json, which
SectorCalculator uses for LIVE sector-split timing and therefore must
only contain tracks with a real surveyed/captured path (fabricating a
path or sector boundary for a track Boxbox has never actually measured
would risk false sector splits). The Race Strategy screen only needs a
name and a length for the AI strategist's context, so it can safely
include every track GT7 has, including the ones tracks_db.json omits
(e.g. "Alsace - Village (Reverse)", "Nürburgring Sprint").

Source: the public domain (CC0) GT7 track dataset at
  https://github.com/jbhoorasingh/gt7-datalogger-track-data
Reverse layouts (identified via each signature's "reverse" field) and
"dropped_captures" entries (tracks with a verified real length but no
usable captured path) are both included here, unlike tracks_db.json.

Usage:
  python3 tools/generate_all_tracks.py /path/to/signatures.json \
      assets/config/all_tracks.json
"""
import json
import sys


def convert(signatures_path, output_path):
    with open(signatures_path) as f:
        data = json.load(f)

    tracks = {}

    for sig in data["signatures"]:
        tracks[sig["official_name"]] = sig["length_m"]
        reverse = sig.get("reverse")
        if reverse:
            # Reverse layouts have the same physical length as their
            # forward counterpart -- the dataset doesn't re-state
            # length_m for the reverse entry since it's identical.
            tracks[reverse["official_name"]] = sig["length_m"]

    for dropped in data.get("dropped_captures", []):
        # These have a verified real length_m but no usable captured
        # path -- fine for a name+length dropdown, just not for
        # SectorCalculator's sector-boundary math.
        tracks[dropped["official_name"]] = dropped["length_m"]

    output = {
        "tracks": [
            {"name": name, "trackLengthMeters": length}
            for name, length in sorted(tracks.items())
        ]
    }

    with open(output_path, "w") as f:
        json.dump(output, f, indent=2)

    print(f"Wrote {len(tracks)} tracks to {output_path}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)
    convert(sys.argv[1], sys.argv[2])
