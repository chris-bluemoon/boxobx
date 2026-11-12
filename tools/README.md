# Boxbox build-time tooling

One-off scripts for generating/regenerating assets checked into the app.
Not run by the app itself at runtime.

## `generate_tracks_db.py`

Regenerates `../assets/config/tracks_db.json` from the public domain
(CC0) GT7 track dataset at
[jbhoorasingh/gt7-datalogger-track-data](https://github.com/jbhoorasingh/gt7-datalogger-track-data).

That dataset has real GT7 track lengths, bounding boxes, and
surveyed/captured racing-line paths, but does **not** publish actual
sector-1/sector-2 split points (GT7 doesn't expose this via telemetry or
any public API). This script derives *approximate* equal-thirds sector
boundaries by walking each track's racing-line path and centering a small
box on the points 1/3 and 2/3 of the way around the lap -- see the
docstring at the top of the script and the comment in
`../lib/services/sector_calculator.dart` for the full caveat.

### Regenerating

```bash
# Download the latest signatures.json from the dataset repo first:
curl -o /tmp/signatures.json \
  https://raw.githubusercontent.com/jbhoorasingh/gt7-datalogger-track-data/main/signatures.json

python3 tools/generate_tracks_db.py /tmp/signatures.json assets/config/tracks_db.json
```

After regenerating, validate the output with:

```bash
dart run test_scripts/tracks_db_load_test.dart
```
