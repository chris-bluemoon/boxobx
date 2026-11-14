#!/usr/bin/env bash
# Convenience wrapper so you don't have to retype the cd/activate/run
# chain every time. Edit DEVICE_IP/DRIVER_NAME below if they ever change
# (e.g. your iPad gets a new DHCP-assigned IP, or you rename your PSN
# profile), or override them for a one-off run with env vars, e.g.:
#   DEVICE_IP=192.168.1.99 ./start_relay.sh
# DEBUG=1 ./start_relay.sh prints parsing diagnostics, including each
# on-screen name that doesn't match the league roster.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CAPTURE_INDEX="${CAPTURE_INDEX:-0}"
DEVICE_IP="${DEVICE_IP:-192.168.1.41}"
DRIVER_NAME="${DRIVER_NAME:-Willy Swerve}"
SAMPLE_HZ="${SAMPLE_HZ:-8}"
NAME_STABILITY="${NAME_STABILITY:-2}"

source venv/bin/activate
exec python3 -u ocr_relay.py \
  --capture-index "$CAPTURE_INDEX" \
  --device-ip "$DEVICE_IP" \
  --driver-name "$DRIVER_NAME" \
  --sample-hz "$SAMPLE_HZ" \
  --name-stability "$NAME_STABILITY" \
  ${DEBUG:+--debug}
