import cv2
import numpy as np

from continuity.board import SQUARE_M, SQUARES_X, SQUARES_Y, _detector, scale_from_views

F, W, H = 1200.0, 1600, 1200
K = np.array([[F, 0, W / 2], [0, F, H / 2], [0, 0, 1]])


def _look_at(eye, target):
    z = target - eye
    z /= np.linalg.norm(z)
    x = np.cross([0, -1, 0], z)
    x /= np.linalg.norm(x)
    y = np.cross(z, x)
    R = np.stack([x, y, z])
    return np.hstack([R, (-R @ eye)[:, None]])


def _render_board(P_world, model_scale):
    """Image of the board lying flat at the origin, seen through world camera P_world.

    The board is printed at SQUARE_M per square; the model is in units where one metre
    is `1 / model_scale` units.
    """
    pixels_per_square = 100
    board_img = _detector().getBoard().generateImage(
        (SQUARES_X * pixels_per_square, SQUARES_Y * pixels_per_square), marginSize=0
    )
    unit = SQUARE_M / model_scale / pixels_per_square  # model units per board pixel
    # Board pixel (u, v) -> model point (u * unit, 0, v * unit), plane y = 0.
    plane_to_world = np.array([[unit, 0, 0], [0, 0, 0], [0, unit, 0], [0, 0, 1]])
    H_board = K @ P_world @ plane_to_world
    canvas = np.full((H, W), 128, np.uint8)
    warped = cv2.warpPerspective(board_img, H_board, (W, H), borderValue=128)
    mask = cv2.warpPerspective(np.ones_like(board_img), H_board, (W, H))
    canvas[mask > 0] = warped[mask > 0]
    return canvas


def test_scale_from_rendered_board():
    model_scale = 0.25  # metres per model unit: the board is 0.14 units per square
    centre = np.array([SQUARES_X, 0, SQUARES_Y]) * SQUARE_M / model_scale / 2
    views = []
    for angle in np.deg2rad([-30, -10, 10, 30]):
        eye = centre + np.array([np.sin(angle) * 0.8, 2.5, -np.cos(angle) * 0.8])
        P = _look_at(eye, centre)
        gray = _render_board(P, model_scale)
        to_norm = lambda pts: (pts - K[:2, 2]) / F
        views.append((gray, P, to_norm))
    scale = scale_from_views(views)
    assert scale is not None
    assert abs(scale - model_scale) / model_scale < 0.02
