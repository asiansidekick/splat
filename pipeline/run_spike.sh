#!/usr/bin/env bash
# Pipeline spike: Polycam raw export -> Gaussian splat (.ply) viewable on iPad.
#
# Usage: run_spike.sh <polycam_export_dir> <output_dir>
#   <polycam_export_dir> is an unzipped Polycam "Raw data" export
#   (contains keyframes/images, keyframes/cameras, keyframes/depth).
#
# Needs an NVIDIA GPU. Run inside the Docker image in this folder.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <polycam_export_dir> <output_dir>" >&2
  exit 1
fi

export_dir=$1
out=$2
mkdir -p "$out"

# 1. Convert ARKit poses, intrinsics and LiDAR depth into nerfstudio format.
ns-process-data polycam \
  --data "$export_dir" \
  --output-dir "$out/processed" \
  --use-depth

# 2. Train a splat with gsplat (splatfacto). Poses come from ARKit, not COLMAP.
ns-train splatfacto \
  --data "$out/processed" \
  --output-dir "$out/train" \
  --viewer.quit-on-train-completion True

config=$(find "$out/train" -name config.yml | sort | tail -n 1)

# 3. Export the trained splat as a .ply file.
ns-export gaussian-splat \
  --load-config "$config" \
  --output-dir "$out/export"

echo "Splat written to $out/export/splat.ply"
