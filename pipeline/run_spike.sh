#!/usr/bin/env bash
# Pipeline spike: phone capture -> Gaussian splat (.ply) viewable on iPad.
#
# Usage: run_spike.sh <source> <input> <output_dir>
#   polycam   <input> is an unzipped Polycam "Raw data" export
#             (contains keyframes/images, keyframes/cameras, keyframes/depth).
#   record3d  <input> is a Record3D .r3d export, or the folder it unzips to.
#   video     <input> is a plain video file; poses come from COLMAP, so
#             there is no LiDAR depth and no real-world scale.
#
# Needs an NVIDIA GPU. Run inside the Docker image in this folder.
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <polycam|record3d|video> <input> <output_dir>" >&2
  exit 1
fi

source=$1
input=$2
out=$3
mkdir -p "$out"

# 1. Convert the capture into nerfstudio format.
case "$source" in
  polycam)
    # ARKit poses, intrinsics and LiDAR depth.
    ns-process-data polycam --data "$input" --output-dir "$out/processed" --use-depth
    ;;
  record3d)
    # A .r3d file is a zip archive.
    if [[ -f "$input" ]]; then
      python -m zipfile -e "$input" "$out/r3d"
      input="$out/r3d"
    fi
    ns-process-data record3d --data "$input" --output-dir "$out/processed"
    ;;
  video)
    ns-process-data video --data "$input" --output-dir "$out/processed"
    ;;
  *)
    echo "unknown source: $source (expected polycam, record3d or video)" >&2
    exit 1
    ;;
esac

# 2. Train a splat with gsplat (splatfacto).
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
