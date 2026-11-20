"""Downloads Apple's Core ML Depth Anything V2 Small (Apache-2.0) into ios/Reset/Models for the build.

Reset uses it to guess depth from the camera picture where the LiDAR gives nothing usable (Phil's iPhone,
2026-11-08). Kept out of git (50 MB); fetched from Hugging Face by CI, file by file from the repo tree.
"""
import json
import os
import sys
import urllib.request

REPO = "apple/coreml-depth-anything-v2-small"
PACKAGE = "DepthAnythingV2SmallF16.mlpackage"
OUT = os.path.join("ios", "Reset", "Models")


def get(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "reset-ci"}), timeout=120) as r:
        return r.read()


def main():
    listing = json.loads(get(f"https://huggingface.co/api/models/{REPO}/tree/main/{PACKAGE}?recursive=true"))
    files = [entry["path"] for entry in listing if entry.get("type") == "file"]
    if not files:
        sys.exit("no files listed for " + PACKAGE)
    for path in files:
        target = os.path.join(OUT, path)
        if os.path.exists(target) and os.path.getsize(target) > 0:
            print("have", path)
            continue
        os.makedirs(os.path.dirname(target), exist_ok=True)
        data = get(f"https://huggingface.co/{REPO}/resolve/main/{path}")
        with open(target, "wb") as f:
            f.write(data)
        print("got", path, len(data))


if __name__ == "__main__":
    main()
