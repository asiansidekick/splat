# Splat

Continuity checks for film sets and props, from phone video. Scoping doc: https://claude.ai/artifact/1HArL85T18GQKTTVCsB6Z9

## Compare two videos

Film the same set twice, for example after take 1 and after the reset for take 2, then:

```sh
pip install -r requirements.txt
python -m continuity take1.mov take2.mov out/
```

It runs fully offline on a laptop CPU, with no GPU or internet needed. In `out/` you get:

- `report.md` and `report.json`: what moved, was added or is gone. Sizes are in centimetres when the printed marker board is in both videos (see `tools/make_marker_board.py` in the pipeline PR; print at 100% scale).
- `change_N.jpg`: the reference and the new view of each change side by side, with the spot circled.
- `changes.ply`: the 3D points (grey unchanged, red gone, green added), viewable in any point cloud viewer.

How it works: both videos are cut down to their sharpest keyframes and reconstructed together in one 3D model with COLMAP, so the unchanged parts of the set line them up automatically. A point that only one video saw is a candidate change. It counts only if the other video looked at the same spot from a similar angle and saw something different there, judged by viewpoint-corrected image patches.

Filming tips: move slowly (blur is the main cause of false alarms), cover the area from a few heights and keep the lighting steady.
