import numpy as np

from continuity.changes import group_changes


def _blob(center, size, n, rng):
    return center + (rng.random((n, 3)) - 0.5) * size


def test_groups_moved_gone_and_added():
    rng = np.random.default_rng(0)
    room = rng.random((2000, 3)) * [5, 3, 4]
    cup_before = _blob([1, 1, 1], [0.1, 0.12, 0.1], 30, rng)
    cup_after = _blob([1.4, 1, 1.1], [0.1, 0.12, 0.1], 30, rng)
    lamp_gone = _blob([4, 1.5, 3], [0.3, 0.6, 0.3], 80, rng)
    chair_added = _blob([2.5, 0.5, 3.2], [0.5, 1.0, 0.5], 150, rng)

    xyz = np.vstack([room, cup_before, cup_after, lamp_gone, chair_added])
    labels = np.array(["static"] * 2000 + ["gone"] * 30 + ["added"] * 30 + ["gone"] * 80 + ["added"] * 150)
    ids = np.arange(len(xyz))

    changes = group_changes(xyz, labels, ids, evidence={})
    kinds = sorted(c.kind for c in changes)
    assert kinds == ["added", "gone", "moved"]

    moved = next(c for c in changes if c.kind == "moved")
    assert np.allclose(moved.displacement, [0.4, 0, 0.1], atol=0.03)
    gone = next(c for c in changes if c.kind == "gone")
    assert np.allclose(gone.centroid, [4, 1.5, 3], atol=0.05)


def test_no_changes_when_everything_static():
    rng = np.random.default_rng(1)
    xyz = rng.random((500, 3))
    labels = np.array(["static"] * 500)
    assert group_changes(xyz, labels, np.arange(500), evidence={}) == []
