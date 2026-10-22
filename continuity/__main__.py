"""Compare two videos of the same set and list what changed.

Usage: python -m continuity <video_a> <video_b> <out_dir> [--keyframes 80]

Runs fully offline. Writes to out_dir:
  report.md     the list of changes, in centimetres if the marker board was seen
  report.json   the same, for the app to read
  changes.ply   the 3D points: grey unchanged, red gone, green added
  change_N.jpg  the reference and the new view of each change, side by side
"""
import argparse
import json
from pathlib import Path

import cv2
import numpy as np

from .board import board_scale
from .changes import classify_points, group_changes
from .keyframes import extract_keyframes
from .reconstruct import reconstruct

COLORS = {"static": (160, 160, 160), "unknown": (90, 90, 90), "gone": (220, 40, 40), "added": (40, 180, 60)}


def main():
    parser = argparse.ArgumentParser(description="Compare two videos of the same set.")
    parser.add_argument("video_a", help="reference video (for example the first take)")
    parser.add_argument("video_b", help="new video to check against the reference")
    parser.add_argument("out_dir")
    parser.add_argument("--keyframes", type=int, default=80, help="keyframes taken from each video")
    args = parser.parse_args()

    out = Path(args.out_dir)
    work = out / "work"
    print("Picking keyframes...")
    frames_a = extract_keyframes(args.video_a, work / "keyframes" / "A", args.keyframes)
    frames_b = extract_keyframes(args.video_b, work / "keyframes" / "B", args.keyframes)

    print("Reconstructing both videos together...")
    model = reconstruct(frames_a, frames_b, work)
    image_root = work / "images"

    print("Comparing...")
    ids, xyz, labels, evidence = classify_points(model, image_root)
    changes = group_changes(xyz, labels, ids, evidence)
    scale = board_scale(model, image_root)

    write_ply(out / "changes.ply", xyz, labels)
    report = build_report(changes, scale, labels)
    (out / "report.json").write_text(json.dumps(report, indent=2))
    for n, change in enumerate(changes, 1):
        write_evidence(out / f"change_{n}.jpg", model, image_root, change)
    (out / "report.md").write_text(render_markdown(report))
    print(render_markdown(report))


def build_report(changes, scale, labels):
    unit, factor = ("cm", scale * 100) if scale else ("model units", 1.0)
    counts = {k: int((labels == k).sum()) for k in ("static", "gone", "added", "unknown")}
    items = []
    for n, c in enumerate(sorted(changes, key=lambda c: -c.points), 1):
        item = {
            "id": n,
            "kind": c.kind,
            "position": np.round(c.centroid * factor, 1).tolist(),
            "size": np.round(c.extent * factor, 1).tolist(),
            "points": c.points,
            "image": f"change_{n}.jpg",
        }
        if c.displacement is not None:
            item["moved_by"] = round(float(np.linalg.norm(c.displacement) * factor), 1)
        items.append(item)
    return {"unit": unit, "board_found": scale is not None, "point_counts": counts, "changes": items}


def render_markdown(report):
    unit = report["unit"]
    lines = ["# Continuity check", ""]
    if not report["board_found"]:
        lines += ["Marker board not found, so sizes are in model units, not centimetres.", ""]
    if not report["changes"]:
        lines.append("No changes found.")
    for item in report["changes"]:
        size = " x ".join(f"{v:g}" for v in item["size"])
        line = f"{item['id']}. **{item['kind']}**, about {size} {unit}"
        if "moved_by" in item:
            line += f", moved {item['moved_by']:g} {unit}"
        lines.append(line + f" ({item['image']})")
    c = report["point_counts"]
    lines += ["", f"Points: {c['static']} unchanged, {c['gone']} gone, {c['added']} added, {c['unknown']} not seen by both."]
    return "\n".join(lines) + "\n"


def write_ply(path, xyz, labels):
    colors = np.array([COLORS[l] for l in labels], dtype=np.uint8)
    header = (
        "ply\nformat ascii 1.0\n"
        f"element vertex {len(xyz)}\n"
        "property float x\nproperty float y\nproperty float z\n"
        "property uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n"
    )
    with open(path, "w") as f:
        f.write(header)
        for p, c in zip(xyz, colors):
            f.write(f"{p[0]:.5f} {p[1]:.5f} {p[2]:.5f} {c[0]} {c[1]} {c[2]}\n")


def write_evidence(path, model, image_root, change):
    """Reference view (left) and new view (right) with the change circled."""
    panels = []
    shown = {c: model.find_image_with_name(n) for c, n in change.views.items() if n}
    if not shown:
        return
    for capture in ("A", "B"):
        image = shown.get(capture) or _closest_view(model, capture, change.centroid, next(iter(shown.values())))
        if image is None:
            continue
        name = image.name
        frame = cv2.imread(str(image_root / name))
        where = change.centroid
        if capture == "A" and change.displacement is not None:
            where = change.centroid - change.displacement  # where it was before it moved
        uv = image.project_point(where)
        if uv is not None:
            center = tuple(int(v) for v in uv)
            cv2.circle(frame, center, 60, (0, 0, 255) if capture == "A" else (0, 200, 0), 6)
        label = "reference" if capture == "A" else "new"
        cv2.putText(frame, label, (30, 70), cv2.FONT_HERSHEY_SIMPLEX, 2, (255, 255, 255), 5)
        panels.append(frame)
    if panels:
        height = min(p.shape[0] for p in panels)
        panels = [cv2.resize(p, (int(p.shape[1] * height / p.shape[0]), height)) for p in panels]
        cv2.imwrite(str(path), np.hstack(panels), [cv2.IMWRITE_JPEG_QUALITY, 85])


def _closest_view(model, capture, xyz, like):
    """The image from `capture` that sees xyz from the direction most like image `like`."""
    want = xyz - like.projection_center()
    want /= np.linalg.norm(want)
    best, best_cos = None, np.cos(np.deg2rad(45))
    for image_id in model.reg_image_ids():
        image = model.image(image_id)
        if not image.name.startswith(capture + "/") or image.project_point(xyz) is None:
            continue
        ray = xyz - image.projection_center()
        cos = ray @ want / np.linalg.norm(ray)
        if cos > best_cos:
            best, best_cos = image, cos
    return best


if __name__ == "__main__":
    main()
