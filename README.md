# Splat

Set and prop continuity for film productions using Gaussian splatting. An iPhone or iPad Pro captures a set (photos, LiDAR depth, ARKit poses), the cloud trains a splat, and the iPad app compares shoot days and shows what moved.

Scoping doc: https://claude.ai/artifact/1HArL85T18GQKTTVCsB6Z9

## Pipeline spike

Goal: check splat quality on a real set before building the app.

1. Capture a room on an iPhone or iPad Pro with one of:
   - **Polycam** (LiDAR mode), exported as **Raw data** and unzipped (`polycam`).
   - **Record3D**, exported as `.r3d` (`record3d`).
   - The Camera app: 1 to 2 minutes of slow video around the room (`video`). No LiDAR depth or real-world scale.
2. On a machine with an NVIDIA GPU (a cloud GPU instance is fine):

   ```sh
   docker build -t splat-pipeline pipeline/
   docker run --gpus all -v /path/to/capture:/data/in -v /path/to/out:/data/out \
     splat-pipeline <polycam|record3d|video> /data/in /data/out
   ```

   For `record3d` and `video`, mount the folder holding the file and pass the file path, e.g. `/data/in/room.r3d`.

3. Open `out/export/splat.ply` on the iPad with a splat viewer such as the MetalSplatter sample app, or on a desktop with SuperSplat.

Training takes roughly 5 to 30 minutes per room on a single modern GPU.
