# Match (iOS)

Photo-only continuity for hair, makeup, costume, props and set. It opens straight into the camera, laid out like the iPhone Camera app so it can be used fast from muscle memory: board and take at the top (tap the take for the next one), angles above the shutter (picking one shows its reference over the camera), one reference thumbnail bottom left (tap for the gallery: pick any photo as the overlay, or compare the latest photo), boards and photos bottom right. Nothing is saved until the shutter is pressed.

In short: take or import a few photos, then check against them before each take. No 3D scan, no internet, no computer. Runs on iPhone and iPad, portrait or landscape.

1. **Boards.** Tap **+** for each character or prop you look after in a scene, for example "Sarah · Hair" in scene 12. The scene and department carry over from the last board. Add notes (hair tucked behind left ear, top button undone).
2. **Take numbering.** Each scene has a take counter (Prep before the first take). Tap **Next take** as takes go by; every board in the scene follows it, and new photos are filed under the current take. Fix any photo's take later with **Edit**.
3. **Reference photos.** Tap **Camera** and shoot. Pick an angle (Front, Left, Right, Back, Detail, Wide) before shooting. The first photo from each angle becomes that angle's reference (★); star or unstar any photo to change it.
4. **Import** QTake screenshots or photos: from Photos (several at once), Files, the clipboard (**Paste**), or by dragging into a board on iPad. On iPad, Match works in Split View next to another app.
5. **Match with the camera.** The camera shows the reference see-through over the live view. Slide to set how strong; tap the square to show outlines only. Pinch and drag the overlay to line up a screenshot framed differently; double tap resets it. Choose another overlay, the angle and the take from the chips. Tap the little thumbnail after a shot to compare it straight away.
6. **Compare** any two photos on a board: **Side** (side by side, both zoom together), **Wipe**, **Blend**, **Flicker**, and **Changes**, which lines the photos up automatically and marks in red what looks different (the slider sets sensitivity). Changes works best when both photos were taken from about the same spot. Share sends the pair as one picture.
7. **Share PDF sheet** (board menu) makes an A4 continuity sheet with notes and every photo grouped by take. AirDrop works without signal.

8. **Home menu (•••)**: **How to use Match** (also shown on first launch), **Tester notes** (jot bugs as they happen, then share them with the build number and device model), and **Back up all boards** (one zip of every photo and note, to AirDrop or save to Files).

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
