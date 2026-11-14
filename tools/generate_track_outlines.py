#!/usr/bin/env python3
"""Generates ../assets/config/track_outlines.json -- each GT7 track's
outline, used to draw the circuit emblem in the app's page headers (see
lib/widgets/track_header.dart).

Source: the public domain (CC0) GT7 track dataset at
github.com/jbhoorasingh/gt7-datalogger-track-data (the same signatures.json
generate_tracks_db.py uses). Each track's surveyed racing-line path is in
driving order in GT7 world X/Z metres; it's thinned to at most
MAX_POINTS points (plenty for a small emblem) and rounded to whole metres.
Drawn with screen x = X and screen y = Z, it matches the orientation of
GT7's own course map (checked against Alsace - Village). Reverse layouts
have the same shape, so the app falls back to the base layout's outline.

Usage:
  curl -o /tmp/signatures.json \\
    https://raw.githubusercontent.com/jbhoorasingh/gt7-datalogger-track-data/main/signatures.json
  python3 tools/generate_track_outlines.py /tmp/signatures.json assets/config/track_outlines.json
"""
import json
import sys

MAX_POINTS = 160


def thin(path):
    step = max(1, -(-len(path) // MAX_POINTS))  # ceil division
    return [[int(round(x)), int(round(z))] for x, z in path[::step]]


def main(signatures_path, output_path):
    with open(signatures_path) as f:
        data = json.load(f)
    outlines = {}
    for sig in data["signatures"]:
        path = sig.get("path")
        if path and len(path) >= 6:
            outlines[sig["official_name"]] = thin(path)
    with open(output_path, "w") as f:
        json.dump(
            {
                "source": "github.com/jbhoorasingh/gt7-datalogger-track-data (CC0)",
                "outlines": outlines,
            },
            f,
            separators=(",", ":"),
        )
    print(f"Wrote {len(outlines)} track outlines to {output_path}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
