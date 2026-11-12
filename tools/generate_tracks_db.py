#!/usr/bin/env python3
"""
Generates assets/config/tracks_db.json for the Boxbox app from the public
domain (CC0) GT7 track dataset at:
  https://github.com/jbhoorasingh/gt7-datalogger-track-data

That project does not publish official sector-1/sector-2 split points
(no track in it has populated "sectors" data, and GT7 itself doesn't
expose this via telemetry or any public API). Instead, this script
derives *approximate* equal-thirds sector boundaries from each track's
surveyed/captured racing-line path (ordered X/Z points, ~20m apart, in
driving order) -- i.e. it walks the path and picks small bounding boxes
around the points closest to 1/3 and 2/3 of the way around the lap. This
is more accurate than a straight hand-guessed bounding box because it's
anchored to the real track shape instead of blind coordinate guessing,
but it is NOT the same thing as GT7's actual (undocumented) in-game
sector boundaries.

Usage:
  python3 tools/generate_tracks_db.py /path/to/signatures.json \
      assets/config/tracks_db.json
"""
import json
import sys


def sector_box(points, index, half_width=15.0):
    """Builds a small square bounding box centered on points[index]."""
    x, z = points[index]
    return {
        "minX": x - half_width,
        "maxX": x + half_width,
        "minZ": z - half_width,
        "maxZ": z + half_width,
    }


def convert(signatures_path, output_path):
    with open(signatures_path) as f:
        data = json.load(f)

    tracks = []
    skipped = 0

    for sig in data["signatures"]:
        path = sig.get("path")
        # Skip tracks with no captured/surveyed path -- we have nothing
        # to derive sector splits from, and a bad guess is worse than no
        # entry (falls back to the app's equal-distance-by-lapDistance
        # logic instead, if/when lap distance becomes available).
        if not path or len(path) < 6:
            skipped += 1
            continue

        third = len(path) // 3
        two_thirds = (2 * len(path)) // 3

        tracks.append({
            "name": sig["official_name"],
            "trackLengthMeters": sig["length_m"],
            "sector1Boundary": sector_box(path, third),
            "sector2Boundary": sector_box(path, two_thirds),
        })

    output = {"tracks": tracks}

    with open(output_path, "w") as f:
        json.dump(output, f, indent=2)

    print(f"Wrote {len(tracks)} tracks to {output_path} ({skipped} skipped, no path data)")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)
    convert(sys.argv[1], sys.argv[2])
