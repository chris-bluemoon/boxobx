#!/usr/bin/env python3
"""One-off diagnostic: captures a single frame from the HDMI capture
card and saves BOTH the full raw frame and the tire-wear ROI crop
proposed by the user's research (x=230-420, y=1830-2060 at 4K), so we
can visually confirm what's actually in that region before building
any real parsing logic around it. Not part of the live relay pipeline.

Usage: python3 capture_tire_wear_roi.py --capture-index 0
"""
import argparse

import cv2


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--capture-index", type=int, default=0)
    parser.add_argument("--full-out", type=str, default="/tmp/tire_wear_full_frame.png")
    parser.add_argument("--crop-out", type=str, default="/tmp/tire_wear_roi_crop.png")
    # Defaults match the coordinates supplied by the user (4K reference).
    parser.add_argument("--x-min", type=int, default=230)
    parser.add_argument("--x-max", type=int, default=420)
    parser.add_argument("--y-min", type=int, default=1830)
    parser.add_argument("--y-max", type=int, default=2060)
    args = parser.parse_args()

    capture = cv2.VideoCapture(args.capture_index)
    if not capture.isOpened():
        raise SystemExit(f"Could not open capture device at index {args.capture_index}")

    ok, frame = capture.read()
    capture.release()
    if not ok:
        raise SystemExit("Could not read a frame from the capture device.")

    height, width = frame.shape[:2]
    print(f"Captured frame resolution: {width}x{height}")

    cv2.imwrite(args.full_out, frame)
    print(f"Saved full frame to {args.full_out}")

    crop = frame[args.y_min:args.y_max, args.x_min:args.x_max]
    if crop.size == 0:
        raise SystemExit(
            f"Crop region (x={args.x_min}-{args.x_max}, y={args.y_min}-{args.y_max}) "
            f"is out of bounds for a {width}x{height} frame."
        )
    cv2.imwrite(args.crop_out, crop)
    print(f"Saved tire-wear ROI crop to {args.crop_out} (shape: {crop.shape})")


if __name__ == "__main__":
    main()
