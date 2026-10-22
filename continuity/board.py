"""Real-world scale from the printed ChArUco marker board (tools/make_marker_board.py)."""
import cv2
import numpy as np

SQUARES_X, SQUARES_Y = 5, 7
SQUARE_M, MARKER_M = 0.035, 0.026


def _detector():
    board = cv2.aruco.CharucoBoard(
        (SQUARES_X, SQUARES_Y),
        SQUARE_M,
        MARKER_M,
        cv2.aruco.getPredefinedDictionary(cv2.aruco.DICT_4X4_50),
    )
    return cv2.aruco.CharucoDetector(board)


def _triangulate(observations):
    """Linear triangulation from (3x4 cam_from_world, normalized image point) pairs."""
    rows = []
    for P, (x, y) in observations:
        rows.append(x * P[2] - P[0])
        rows.append(y * P[2] - P[1])
    _, _, vt = np.linalg.svd(np.array(rows))
    X = vt[-1]
    return X[:3] / X[3]


def board_scale(model, image_root):
    """Metres per model unit, or None if the board was not seen well enough.

    Board corners are found in every registered image, triangulated with the
    reconstructed camera poses, and the distances between neighbouring corners are
    compared with the printed square size.
    """
    views = []
    for image_id in model.reg_image_ids():
        image = model.image(image_id)
        gray = cv2.imread(str(image_root / image.name), cv2.IMREAD_GRAYSCALE)
        views.append((gray, image.cam_from_world().matrix(), image.camera.cam_from_img))
    return scale_from_views(views)


def scale_from_views(views):
    """Metres per model unit from (grayscale image, 3x4 cam_from_world, cam_from_img) views."""
    detector = _detector()
    corner_views = {}
    for gray, P, cam_from_img in views:
        corners, corner_ids, _, _ = detector.detectBoard(gray)
        if corner_ids is None:
            continue
        normalized = cam_from_img(corners.reshape(-1, 2).astype(np.float64))
        for cid, xy in zip(corner_ids.ravel(), normalized):
            corner_views.setdefault(int(cid), []).append((P, xy))

    points = {cid: _triangulate(obs) for cid, obs in corner_views.items() if len(obs) >= 3}
    per_row = SQUARES_X - 1
    distances = []
    for cid, xyz in points.items():
        right, below = cid + 1, cid + per_row
        if cid % per_row != per_row - 1 and right in points:
            distances.append(np.linalg.norm(points[right] - xyz))
        if below in points:
            distances.append(np.linalg.norm(points[below] - xyz))
    if len(distances) < 4:
        return None
    return SQUARE_M / float(np.median(distances))
