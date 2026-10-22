"""Reconstruct two videos' keyframes into one shared 3D model with COLMAP.

Reconstructing both captures together puts them in the same coordinate frame for
free: the unchanged parts of the set (walls, floor, fixed furniture) tie them together.
"""
import shutil
from pathlib import Path

import pycolmap


def reconstruct(frames_a, frames_b, work_dir):
    """Run feature extraction, matching and mapping on both keyframe sets.

    Images are stored as A/<name> and B/<name>, one camera per video.
    Returns the largest pycolmap.Reconstruction.
    """
    work_dir = Path(work_dir)
    image_root = work_dir / "images"
    for label, frames in (("A", frames_a), ("B", frames_b)):
        dest = image_root / label
        dest.mkdir(parents=True, exist_ok=True)
        for path in frames:
            shutil.copy(path, dest / Path(path).name)

    database = work_dir / "database.db"
    if database.exists():
        database.unlink()
    pycolmap.extract_features(
        database,
        image_root,
        camera_mode=pycolmap.CameraMode.PER_FOLDER,
        device=pycolmap.Device.auto,
    )
    pycolmap.match_exhaustive(database, device=pycolmap.Device.auto)

    sparse_dir = work_dir / "sparse"
    sparse_dir.mkdir(exist_ok=True)
    models = pycolmap.incremental_mapping(database, image_root, sparse_dir)
    if not models:
        raise RuntimeError("COLMAP could not reconstruct the captures; they may be too blurry or too short")
    model = max(models.values(), key=lambda m: m.num_reg_images())

    registered = {model.image(i).name.split("/")[0] for i in model.reg_image_ids()}
    if registered != {"A", "B"}:
        raise RuntimeError(
            "only one capture could be placed in the 3D model; the two videos need more overlapping views"
        )
    return model


def video_of(image):
    """Which capture ('A' or 'B') an image belongs to."""
    return image.name.split("/")[0]
