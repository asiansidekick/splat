# Match (iOS)

Photo-only continuity for hair, makeup and costume. It opens straight into the camera, laid out like Reset and the iPhone Camera app so it can be used fast from muscle memory: the camera fills the screen; scene, character and take at the top; angles above the shutter (Any, Front, ¾ L, Left, Back, Right, ¾ R, Close, Full; picking one shows its reference over the camera); one reference thumbnail bottom left (tap for a swipeable gallery: Use as overlay, Compare, import and save to Photos); Next take bottom right. Nothing is saved until the shutter is pressed.

**Guide.** With a reference showing, the guide stays at the edges and corners of the screen, leaving the face and hair clear. Yellow corner brackets show where the reference's frame sits now, and white ones mark the screen; line them up. One big, see-through, slowly pulsing instruction shows at a time, held for at least 1.5 s, in camera words: MOVE, PAN, TILT, ROTATE, STEP IN or STEP BACK. Hold still lined up for half a second and the corners turn green. It works from the pictures alone (Vision image registration), so it runs on every iPhone and iPad, with no LiDAR. The overlay strength slider sits in the bottom left corner.

**Actor lock.** When the reference has a person in it, the guide and the overlay lock to the actor rather than the room, using Vision on the back camera: face landmarks (eyes, nose, mouth) for hair and makeup, body pose (shoulders, neck, hips) for costume boards. The ghost is pinned to the eyes or shoulders, and the guide adds WALK ROUND LEFT/RIGHT (from where the nose sits between the eyes) and RAISE/LOWER PHONE (from where the nose sits between eyes and mouth). With several people in view, tap one to follow them. Detection only, never identity, fully offline. The maths is tested on CI against a modelled head photographed by a pinhole camera (`Tests/ActorTests`).

**LiDAR distance.** On iPhones and iPads with LiDAR, Match uses the LiDAR camera (AVFoundation depth, no ARKit). Each photo saves a small depth map beside it (`<id>-depth.bin`), and STEP IN/BACK then goes by the measured distance to the actor's eyes or shoulders (or the reference's middle), with how far to move in centimetres. It can be turned off in the ••• menu; without LiDAR the guide goes by how big things look.

In short: take or import a few photos, then check against them before each take. No 3D scan, no internet, no computer. Runs on iPhone and iPad, portrait or landscape.

1. **Boards.** Tap **+** for each character or prop you look after in a scene, for example "Sarah · Hair" in scene 12. The scene and department carry over from the last board. Add notes (hair tucked behind left ear, top button undone).
2. **Take numbering.** Each scene has a take counter (Prep before the first take). Tap **Next take** as takes go by; every board in the scene follows it, and new photos are filed under the current take. Fix any photo's take later with **Edit**.
3. **Reference photos.** Tap **Camera** and shoot. Pick an angle (Front, ¾ Left, Left, Back, Right, ¾ Right, Close-up, Full length) before shooting. The first photo from each angle becomes that angle's reference (★); star or unstar any photo to change it.
4. **Import** QTake screenshots or photos: from Photos (several at once), Files, the clipboard (**Paste**), or by dragging into a board on iPad. On iPad, Match works in Split View next to another app.
5. **Match with the camera.** The camera shows the reference see-through over the live view. Slide to set how strong; tap the square to show outlines only. Pinch and drag the overlay to line up a screenshot framed differently; double tap resets it. Choose another overlay, the angle and the take from the chips. Tap the little thumbnail after a shot to compare it straight away.
6. **Compare** any two photos on a board: **Side** (side by side, both zoom together), **Wipe**, **Blend**, **Flicker**, and **Changes**, which lines the photos up automatically and marks in red what looks different (the slider sets sensitivity). Changes works best when both photos were taken from about the same spot. Share sends the pair as one picture.
7. **Share PDF sheet** (board menu) makes an A4 continuity sheet with notes and every photo grouped by take. AirDrop works without signal.

8. **Send to team (AirDrop)** (Home or board menu) packs boards into one `.matchpack` file for AirDrop, phone to phone with no internet. References only or all photos; locked with a team passcode (AES-GCM, PBKDF2 key, kept in the keychain on this device only); photos lose location, phone model and time-taken details; Messages, Mail and copy are removed from the sheet; the pack is deleted after sending. Opening a pack in Match adds new boards and photos and never overwrites what the receiver already has. Tested in CI by `Tests/PackTests`.
9. **Home menu (•••)**: **How to use Match** (also shown on first launch), **Tester notes** (jot bugs as they happen, then share them with the build number and device model), and **Back up all boards** (one zip of every photo and note, to AirDrop or save to Files).

Photos are stored in the app's Documents folder (visible in the Files app). Re-sideloading over the top keeps them; deleting the app deletes them, so back up first.

## Install without a Mac

Every push that touches `ios/Match` builds an unsigned IPA on GitHub Actions (`.github/workflows/ios-match.yml`). Download the **Match-build-N** artifact from the run (N is the run number, also shown at the bottom of the app's home screen) and install `Match-build-N.ipa` with Sideloadly using your Apple ID.

## Build with a Mac

```sh
brew install xcodegen
cd ios/Match
xcodegen
open Match.xcodeproj
```
