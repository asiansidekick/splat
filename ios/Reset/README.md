# Reset (iOS)

Put a set back the way it was, entirely on an iPhone or iPad. No internet, no computer.

1. **Record a reference** before the first take: tap **+**, name it (for example "12B setup 1"), tap **Start** and walk slowly around the area, pointing at the props. When the status says **Mapped**, tap **Save reference**. On LiDAR devices, leave **Use LiDAR** on.
2. **Reset** after a take: open the reference and point at the set. Once it recognises the room, it shows:
   - the closest reference photo as a see-through **ghost** over the live camera (slider sets how strong),
   - directions to stand where that photo was taken ("Move 20 cm left, then turn 8°"), turning green when you match,
   - with LiDAR, **red** where something is now in front of where it was and **blue** where something is missing.
   Tap **Hold this view** to keep one reference photo while you nudge props into place.

References are stored in the app's Documents folder (visible in the Files app).

## Build

Needs a Mac with Xcode 15 or later, and an iPhone or iPad (ARKit does not run in the simulator).

```sh
brew install xcodegen
cd ios/Reset
xcodegen
open Reset.xcodeproj
```

In Xcode, select the **Reset** target, set your Apple ID team under **Signing & Capabilities**, plug in the device and press Run.
