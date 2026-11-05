# Scan (test app)

Object scanning for Reset, rebuilt on Apple's own Object Capture instead of our LiDAR mesh code.

- `ObjectCaptureSession` + `ObjectCaptureView` take the pictures, with Apple's box, dial and
  guidance (the same engine as Reality Composer and many commercial scanners).
- `PhotogrammetrySession` builds a real-size, textured USDZ on the phone (iOS 17+, LiDAR devices).
- Scans live in Files > On My iPhone > Scan > Scans. Each keeps its pictures, so a model can be
  rebuilt from the library, or on a Mac later at higher detail.
- Import a scan into Reset with its 3D models button.

Built by `.github/workflows/ios-scan.yml`; the unsigned IPA is sideloaded like Reset.
It is a separate app (bundle id `com.asiansidekick.scan`) so Reset's main work is untouched; it
will move into Reset once it scans reliably.
