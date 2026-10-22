"""Pick sharp, evenly spaced keyframes from a phone video."""
from pathlib import Path

import cv2
import numpy as np


def sharpness(gray):
    """Variance of the Laplacian: higher means less motion blur."""
    return cv2.Laplacian(gray, cv2.CV_64F).var()


def extract_keyframes(video_path, out_dir, count=80, max_side=1600):
    """Split the video into `count` equal time slices and keep the sharpest frame of each.

    Frames are downscaled so the longest side is `max_side` pixels and saved as JPEG.
    Returns the list of written paths.
    """
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    cap = cv2.VideoCapture(str(video_path))
    if not cap.isOpened():
        raise RuntimeError(f"cannot open video: {video_path}")
    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    if total <= 0:
        raise RuntimeError(f"video has no frames: {video_path}")
    count = min(count, total)
    bounds = np.linspace(0, total, count + 1).astype(int)

    best = {}  # slice index -> (sharpness, frame)
    index = 0
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        slice_idx = min(np.searchsorted(bounds, index, side="right") - 1, count - 1)
        small = cv2.resize(frame, None, fx=0.25, fy=0.25, interpolation=cv2.INTER_AREA)
        score = sharpness(cv2.cvtColor(small, cv2.COLOR_BGR2GRAY))
        if slice_idx not in best or score > best[slice_idx][0]:
            best[slice_idx] = (score, frame)
        index += 1
    cap.release()

    paths = []
    for slice_idx in sorted(best):
        frame = best[slice_idx][1]
        scale = max_side / max(frame.shape[:2])
        if scale < 1:
            frame = cv2.resize(frame, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
        path = out_dir / f"{slice_idx:04d}.jpg"
        cv2.imwrite(str(path), frame, [cv2.IMWRITE_JPEG_QUALITY, 92])
        paths.append(path)
    return paths
