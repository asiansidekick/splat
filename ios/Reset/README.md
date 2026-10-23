# Reset (iOS)

Put a set back the way it was, entirely on an iPhone or iPad. No internet, no computer.

1. **Record a reference** for each setup before the first take: tap **+**. Scene and setup are filled in for you (it carries on in the latest scene with the next free setup letter, skipping I and O), so just add an optional description, tap **Start** and walk slowly around the area, pointing at the props. When the status says **Mapped**, tap **Save reference**. On LiDAR devices, leave **Use LiDAR** on.
2. **Reset** after a take: open the reference and point at the set. Once it recognises the room, it shows:
   - the closest reference photo as a see-through **ghost** over the live camera (slider sets how strong),
   - directions to stand where that photo was taken ("Move 20 cm left, then turn 8°"), turning green when you match,
   - with LiDAR, **red** where something is now in front of where it was and **blue** where something is missing.
   Tap **Hold this view** to keep one reference photo while you nudge props into place.

3. **Log takes** from the reset screen: the panel shows the next take number. Tap **Log take** after each take. It ticks "Set matched the reference" when you were lined up, and you can circle the take and add notes. **Take log** lists every take for the setup: tap one to fix its number or notes, swipe to delete, tap the slate to correct the scene or setup, and **Share** sends a plain text take report (AirDrop works without signal).

The home screen groups setups by scene.

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

## TestFlight (no computer needed to install)

`.github/workflows/testflight.yml` builds, signs and uploads every push to TestFlight once these repository secrets exist (Settings, Secrets and variables, Actions):

| Secret | Where it comes from |
| --- | --- |
| `APPLE_TEAM_ID` | developer.apple.com, Account, Membership details, Team ID |
| `ASC_KEY_ID` | App Store Connect, Users and Access, Integrations, App Store Connect API: the key's ID (Admin access) |
| `ASC_ISSUER_ID` | Same page, Issuer ID above the key list |
| `ASC_KEY_P8` | The whole text of the downloaded `AuthKey_XXXX.p8` file, including the BEGIN and END lines |

The first run registers the bundle ID `com.asiansidekick.reset`. Then create the app once in App Store Connect (Apps, +, New App, that bundle ID) and run the workflow again. Builds appear in the TestFlight app after Apple processes them.
