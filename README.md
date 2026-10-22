# Splat

Set and prop continuity for film productions using Gaussian splatting. An iPhone or iPad Pro captures a set (photos, LiDAR depth, ARKit poses), the cloud trains a splat, and the iPad app compares shoot days and shows what moved.

Scoping doc: https://claude.ai/artifact/1HArL85T18GQKTTVCsB6Z9

## Pipeline spike

Goal: check splat quality on a real set before building the app.

1. Capture a room with Polycam (LiDAR mode) on an iPhone or iPad Pro.
2. Export with **Raw data** and unzip it.
3. On a machine with an NVIDIA GPU (a cloud GPU instance is fine):

   ```sh
   docker build -t splat-pipeline pipeline/
   docker run --gpus all -v /path/to/export:/data/in -v /path/to/out:/data/out \
     splat-pipeline /data/in /data/out
   ```

4. Open `out/export/splat.ply` on the iPad with a splat viewer such as the MetalSplatter sample app, or on a desktop with SuperSplat.

Training takes roughly 5 to 30 minutes per room on a single modern GPU.
