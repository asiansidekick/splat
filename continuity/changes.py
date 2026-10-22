"""Find what changed between capture A and capture B in a shared COLMAP model.

A 3D point seen by both captures is part of the unchanged set. A point seen by only one
capture is a candidate change; it counts only if the other capture looked at that spot
and saw something different there. That check compares small image patches with
normalized cross-correlation, so a lighting change between takes does not count.
"""
from dataclasses import dataclass, field

import cv2
import numpy as np
from scipy.spatial import cKDTree
from sklearn.cluster import DBSCAN

from .reconstruct import video_of

PATCH = 15  # half size of the comparison patch, in pixels
MAX_VIEW_ANGLE = np.deg2rad(30)  # views further apart than this are not compared
NCC_SAME = 0.5  # patches at least this similar show the same surface
MIN_TRACK = 4  # a candidate change must be seen in at least this many frames
MIN_TRIANGULATION = np.deg2rad(4)  # and from viewpoints at least this far apart, so its depth is reliable
OCCLUDER_RADIUS = 40  # pixels around a projection searched for something in front of it
OCCLUDER_DEPTH = 0.9  # a point nearer than this fraction of the depth hides it


@dataclass(eq=False)
class Change:
    kind: str  # "gone", "added" or "moved"
    centroid: np.ndarray
    extent: np.ndarray
    points: int
    displacement: np.ndarray = None
    views: dict = field(default_factory=dict)  # capture -> image name showing the change


def _center(image):
    return image.projection_center()


def _project(image, xyz):
    """Pixel position of xyz in image, or None if behind the camera or outside the frame."""
    cam = image.cam_from_world().matrix() @ np.append(xyz, 1.0)
    if cam[2] <= 0:
        return None
    uv = image.camera.img_from_cam(cam[None, :])[0]
    margin = PATCH + 1
    if not (margin <= uv[0] < image.camera.width - margin and margin <= uv[1] < image.camera.height - margin):
        return None
    return uv


def _patch(gray, uv):
    x, y = int(round(uv[0])), int(round(uv[1]))
    return gray[y - PATCH : y + PATCH + 1, x - PATCH : x + PATCH + 1].astype(np.float32)


def _warped_patch(gray_other, own, other, xyz, uv_own):
    """The other view's pixels around xyz, resampled onto the own view's patch grid.

    A small square facing the own camera is projected into both views, and the
    homography between the two projections undoes the change in viewpoint, roll and scale.
    """
    world_to_own = own.cam_from_world().matrix()
    depth = (world_to_own @ np.append(xyz, 1.0))[2]
    focal = own.camera.mean_focal_length()
    step = depth * PATCH / focal
    axis_x, axis_y = world_to_own[0, :3], world_to_own[1, :3]
    corners = [xyz + step * (sx * axis_x + sy * axis_y) for sx, sy in ((-1, -1), (1, -1), (1, 1), (-1, 1))]
    in_own = [_project_any(own, c) for c in corners]
    in_other = [_project_any(other, c) for c in corners]
    if any(p is None for p in in_own + in_other):
        return None
    H = cv2.getPerspectiveTransform(np.float32(in_own), np.float32(in_other))
    offsets = np.arange(-PATCH, PATCH + 1, dtype=np.float32)
    gx, gy = np.meshgrid(uv_own[0] + offsets, uv_own[1] + offsets)
    grid = cv2.perspectiveTransform(np.stack([gx, gy], -1).reshape(-1, 1, 2), H).reshape(gx.shape + (2,))
    grid = np.ascontiguousarray(grid, dtype=np.float32)
    return cv2.remap(gray_other, grid, None, cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE).astype(np.float32)


def _project_any(image, xyz):
    """Pixel position of xyz even if outside the frame; None if behind the camera."""
    cam = image.cam_from_world().matrix() @ np.append(xyz, 1.0)
    return None if cam[2] <= 0 else image.camera.img_from_cam(cam[None, :])[0]


def _ncc(a, b):
    a = a - a.mean()
    b = b - b.mean()
    denom = np.sqrt((a * a).sum() * (b * b).sum())
    return float((a * b).sum() / denom) if denom > 1e-6 else 0.0


class _Images:
    """Lazy grayscale images, and the depth of each image's own reconstructed points."""

    def __init__(self, image_root, model):
        self.root = image_root
        self.model = model
        self.cache = {}
        self.depths = {}

    def occluded(self, image, xyz):
        """True if this image saw some other surface in front of xyz."""
        if image.name not in self.depths:
            world_to_cam = image.cam_from_world().matrix()
            uvs, zs = [], []
            for p2d in image.points2D:
                if p2d.has_point3D():
                    point = self.model.point3D(p2d.point3D_id)
                    uvs.append(p2d.xy)
                    zs.append((world_to_cam @ np.append(point.xyz, 1.0))[2])
            self.depths[image.name] = (cKDTree(np.array(uvs)) if uvs else None, np.array(zs))
        tree, zs = self.depths[image.name]
        if tree is None:
            return False
        depth = (image.cam_from_world().matrix() @ np.append(xyz, 1.0))[2]
        near = tree.query_ball_point(_project(image, xyz), OCCLUDER_RADIUS)
        return bool(near) and zs[near].min() < OCCLUDER_DEPTH * depth

    def gray(self, image):
        if image.name not in self.cache:
            gray = cv2.imread(str(self.root / image.name), cv2.IMREAD_GRAYSCALE)
            # Soften motion blur and sensor noise so they do not read as change.
            self.cache[image.name] = cv2.GaussianBlur(gray, (0, 0), 2)
        return self.cache[image.name]


def classify_points(model, image_root):
    """Label each 3D point 'static', 'gone' (A only), 'added' (B only) or 'unknown'.

    Returns (ids, xyz, labels, evidence) where evidence maps point id -> {capture: image name}
    for the pair of views that were compared.
    """
    images = _Images(image_root, model)
    by_video = {"A": [], "B": []}
    for image_id in model.reg_image_ids():
        image = model.image(image_id)
        by_video[video_of(image)].append(image)

    ids, xyz, labels, evidence = [], [], [], {}
    for point_id, point in model.points3D.items():
        seen = {}
        for element in point.track.elements:
            image = model.image(element.image_id)
            seen.setdefault(video_of(image), []).append(image)
        ids.append(point_id)
        xyz.append(point.xyz)
        if len(seen) == 2:
            labels.append("static")
            continue
        (have,) = seen
        if not _well_placed(point.xyz, seen[have]):
            labels.append("unknown")
            continue
        other = "B" if have == "A" else "A"
        label, views = _check_other_view(point.xyz, seen[have], by_video[other], images)
        if label == "changed":
            labels.append("gone" if have == "A" else "added")
            evidence[point_id] = views
        else:
            labels.append(label)
    return np.array(ids), np.array(xyz), np.array(labels), evidence


def _well_placed(xyz, views):
    """True if the point was triangulated from enough frames with a wide enough baseline."""
    if len(views) < MIN_TRACK:
        return False
    rays = np.array([xyz - _center(v) for v in views])
    rays /= np.linalg.norm(rays, axis=1, keepdims=True)
    return np.arccos(np.clip(rays @ rays.T, -1, 1)).max() >= MIN_TRIANGULATION


def _check_other_view(xyz, own_views, other_views, images):
    """'changed' if the other capture looked here and saw something different, 'static' if
    it saw the same surface, 'unknown' if it never looked from a similar angle."""
    best = []
    for own in own_views:
        ray_own = xyz - _center(own)
        ray_own /= np.linalg.norm(ray_own)
        uv_own = _project(own, xyz)
        if uv_own is None:
            continue
        for other in other_views:
            ray_other = xyz - _center(other)
            ray_other /= np.linalg.norm(ray_other)
            angle = np.arccos(np.clip(ray_own @ ray_other, -1, 1))
            if angle > MAX_VIEW_ANGLE:
                continue
            uv_other = _project(other, xyz)
            if uv_other is not None and not images.occluded(other, xyz):
                best.append((angle, own, uv_own, other, uv_other))
    if not best:
        return "unknown", None
    best.sort(key=lambda b: b[0])
    scores = []
    for _, own, uv_own, other, _ in best[:3]:
        warped = _warped_patch(images.gray(other), own, other, xyz, uv_own)
        if warped is not None:
            scores.append(_ncc(_patch(images.gray(own), uv_own), warped))
    if not scores:
        return "unknown", None
    if max(scores) >= NCC_SAME:
        return "static", None
    _, own, _, other, _ = best[0]
    return "changed", {video_of(own): own.name, video_of(other): other.name}


def scene_scale(xyz):
    """Size of the scene: diagonal of the 5th-95th percentile bounding box."""
    lo, hi = np.percentile(xyz, [5, 95], axis=0)
    return float(np.linalg.norm(hi - lo))


def group_changes(xyz, labels, ids, evidence, min_points=6, eps_fraction=0.03, max_move_fraction=0.25):
    """Cluster changed points into objects and pair a 'gone' with a nearby 'added' of similar size as 'moved'."""
    scale = scene_scale(xyz)
    eps = eps_fraction * scale
    clusters = {"gone": [], "added": []}
    for kind in clusters:
        mask = labels == kind
        if mask.sum() < min_points:
            continue
        pts, pids = xyz[mask], ids[mask]
        groups = DBSCAN(eps=eps, min_samples=min_points).fit_predict(pts)
        for g in set(groups) - {-1}:
            member = groups == g
            cluster_pts = pts[member]
            names = [evidence[p] for p in pids[member] if p in evidence]
            clusters[kind].append(
                Change(
                    kind=kind,
                    centroid=cluster_pts.mean(axis=0),
                    extent=np.ptp(cluster_pts, axis=0),
                    points=int(member.sum()),
                    views=names[0] if names else {},
                )
            )

    changes = []
    added = list(clusters["added"])
    for gone in sorted(clusters["gone"], key=lambda c: -c.points):
        match = _similar(gone, added, max_move_fraction * scale)
        if match is None:
            changes.append(gone)
            continue
        added.remove(match)
        changes.append(
            Change(
                kind="moved",
                centroid=match.centroid,
                extent=match.extent,
                points=gone.points + match.points,
                displacement=match.centroid - gone.centroid,
                views={"A": gone.views.get("A"), "B": match.views.get("B")},
            )
        )
    return changes + added


def _similar(gone, candidates, max_move):
    """The added cluster within `max_move` most likely to be the same object as `gone`, by size."""
    best, best_ratio = None, 1.6
    size_gone = np.sort(gone.extent)
    for cand in candidates:
        if np.linalg.norm(cand.centroid - gone.centroid) > max_move:
            continue
        size_cand = np.sort(cand.extent)
        ratio = np.max(np.maximum(size_gone, 1e-9) / np.maximum(size_cand, 1e-9))
        ratio = max(ratio, np.max(np.maximum(size_cand, 1e-9) / np.maximum(size_gone, 1e-9)))
        if ratio < best_ratio:
            best, best_ratio = cand, ratio
    return best
