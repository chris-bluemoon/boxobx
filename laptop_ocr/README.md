# Boxbox Laptop HUD OCR Relay

Runs on the laptop that has the USB HDMI capture card plugged in (the card
mirrors the PS5 HDMI output). Captures frames with OpenCV, crops the
left-hand 20%-width leaderboard ROI, runs OCR at ~5Hz, and streams parsed
leaderboard JSON to the iPhone or iPad running the Boxbox app over UDP
port 33746 (matching `HudOcrService` in the Flutter app).

## Why on the laptop and not on the phone/tablet?

A phone or tablet decoding a raw 1080p UVC video feed while running OCR
concurrently would compete for the same CPU/GPU resources used for video
decode, risking thermal throttling, dropped frames, and growing HUD lag
over a long racing session. Running OCR on a laptop (with a
dedicated/better-cooled CPU, and optionally a GPU for EasyOCR) keeps this
pipeline stable, leaving the mobile device free to only handle UDP
telemetry ingestion, the fused race state, and the voice engine.

This also means the mobile device doesn't need a USB-C capture-card
connection at all — an iPhone or a Lightning-only iPad works exactly the
same as a USB-C iPad for this architecture, since everything from the
laptop arrives purely over Wi-Fi/UDP.

## Setup

```bash
cd laptop_ocr
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
python ocr_relay.py --capture-index 0 --device-ip 192.168.1.50 --driver-name "Your PSN Name"
```

Once the venv is set up, you can start the relay with a single command
instead of retyping the full invocation every time:

```bash
./start_relay.sh
```

Edit the `CAPTURE_INDEX`/`DEVICE_IP`/`DRIVER_NAME` defaults at the top of
`start_relay.sh` if they ever change, or override them for a one-off run
without editing the file:

```bash
DEVICE_IP=192.168.1.99 ./start_relay.sh
```

- `--capture-index`: OpenCV device index of the USB capture card (list
  available devices with `ocr_relay.py --list-devices`).
- `--device-ip`: local network IP address of the iPhone/iPad running
  Boxbox (find it under iOS Settings → Wi-Fi → tap the connected
  network's info icon).
- `--driver-name`: your exact GT7 PSN display name, used to locate your
  own row in the on-screen leaderboard so `driverAhead`/`driverBehind`
  are extracted relative to your actual race position (the row
  immediately above/below yours), rather than guessing from raw OCR line
  order. Matching is a loose substring match to tolerate OCR noise (e.g.
  "Willy Swerve" still matches if OCR reads it as "Wiily Swerve").
- `--roi-width-pct`: fraction of frame width to crop from the left edge
  (default `0.20`, matching the leaderboard strip location).
- `--sample-hz`: OCR sampling rate (default `8`). Higher = faster
  driverAhead/driverBehind updates on real overtakes, at the cost of
  more CPU load per second. The capture/OCR/send loop is synchronous, so
  if an OCR pass takes longer than the sample interval on a slower
  machine, the effective rate just throttles down rather than queuing
  up or crashing -- lower this if CPU usage becomes a problem.
- `--name-stability`: number of consecutive samples a genuinely
  different driverAhead/driverBehind name must be read before it's
  accepted (default `2`), to filter out a single noisy OCR misread
  without being slow to react to a real overtake. At 8Hz/stability=2 a
  real name change resolves in ~250ms; the original 5Hz/stability=3
  combination took up to ~600ms+ and was reported as feeling laggy in
  practice. Raise this back up if you still see occasional flicker
  between two names on a noisy capture setup.

The script prints each frame's OCR output to stdout for debugging, and
sends the structured JSON payload (`gridPosition`, `driverAhead`,
`driverBehind`, `gapAheadSeconds`, `gapAheadTrend`, `gapBehindSeconds`,
`gapBehindTrend`) as a single UDP datagram per sample.

### Gap seconds and trend (the actually-useful metric)

Just showing who's ahead/behind by name is something the driver can
already see directly on GT7's own HUD. The metric Gunther actually needs
is whether that gap is **shrinking or growing** -- that's what
`gapAheadTrend`/`gapBehindTrend` report, as one of `"closing"`,
`"losing"`, `"steady"`, or `"unknown"` (not enough recent history yet,
or the rival isn't currently visible in the on-screen leaderboard).

This is computed by `GapTracker`, which keeps a short rolling window of
the last several gap readings (default 5 samples at 5Hz = ~1 second) per
role (ahead/behind) and compares the latest reading against the average
of the rest of the window. A single noisy OCR misread of the gap digits
won't trigger a false trend change; a sustained shrink/grow over that
window will. See `test_gap_tracker.py` for worked examples.

GT7's actual on-screen gap format is `+M:SS` (e.g. `+1:51`, `+2:00`),
confirmed against a real race screenshot -- not decimal seconds as the
original design assumed. `_parse_gap_seconds()` parses this correctly
(with a decimal-seconds fallback in case GT7 ever uses that format for
very close gaps).

### "Fastest Lap" row

GT7 shows a separate "FL &lt;driver name&gt; &lt;lap time&gt;" row below the
main standings (e.g. `FL N. Kovacs 1:53.128`), which caused two real bugs
found by testing against a last-place/FL-visible race:

1. The FL row was occasionally misread by OCR in a way that slipped past
   the position-number filter, contaminating `driverBehind` with the
   fastest-lap holder's name instead of correctly reporting `null`.
2. The lap time itself (`1:53.128`) shares the same leading `M:SS` shape
   as a real gap (`+1:51`), so it could be misparsed as a ~113 second
   gap. `_parse_gap_seconds()` now explicitly rejects any `M:SS` match
   immediately followed by `.digits` (a lap time), since GT7's actual gap
   display never includes decimal sub-seconds.

Both are covered by dedicated regression tests in `test_gap_tracker.py`.

### How the leaderboard parsing works

GT7's on-screen leaderboard only shows a handful of rows near your own
position (e.g. positions 16-20 if you're 20th), each row rendered as a
position number followed by the driver's name. The relay:

1. Runs OCR with bounding boxes (not just flat text) so it knows the
   (x, y) location of every recognized text fragment.
2. Groups fragments into rows by vertical (y) proximity.
3. Keeps only rows that start with a standalone 1-2 digit number (the
   position column) — this filters out the "POSITION"/"LAP" header text
   and course-map HUD clutter above/below the actual standings list.
4. Finds your own row by matching `--driver-name` against each row's
   name text.
5. Returns the row immediately above as `driverAhead` and the row
   immediately below as `driverBehind` (either may be `null` if you're
   P1 or last place).

This only works correctly while GT7 is actually showing a real
leaderboard with other cars — e.g. Sport Mode, Arcade vs. AI, or a
lobby race. **Time Trial has no leaderboard at all** (it's a solo mode),
so in Time Trial the relay will correctly find no driver-name match and
report `driverAhead`/`driverBehind` as `null`.

## Network requirements

The PS5, the laptop running this relay, and the iPhone/iPad running
Boxbox must all be on the same local Wi-Fi network/subnet. Two
independent UDP streams converge on the mobile device:

| Data | Source | Port |
|---|---|---|
| RPM/speed/gear/position/fuel/tires | PS5/GT7 directly (see telemetry_udp_service.dart) | 33740 (receive) / 33739 (heartbeat) |
| Grid position/rival names/gaps | This laptop relay | 33746 |

If your network has client isolation enabled (common on guest networks),
either or both UDP paths will silently fail — use the dashboard's
connection status badges in the app to confirm both are showing `LIVE`.
