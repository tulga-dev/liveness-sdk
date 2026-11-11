# liveness_sdk (Flutter)

Capture side of the head-turn liveness check, for Android and iOS. It opens the front
camera, asks the user to look straight and then make the turns the server chose, takes
four photos automatically, and uploads them. The verdict is decided on the server and
read by your backend; the app is only told the upload is complete.

On-device face tracking uses `face_detection_tflite` (MediaPipe models, Apache-2.0).
It only guides the capture. The security decision is made by the server.

**Status:** pilot. `stable` (0.1.0) has run end to end on an Android emulator. `main` and `beta` (0.2.0) add a burst of frames per head turn and are still being tested on devices.

The screen shows the face in a circle with a ring of tick marks. For each step the ticks on the
side to turn towards light up as the head moves, and the photo is taken automatically when that
section is full. A "Take photo now" button appears after 6 seconds as a fallback.

Building for Android needs the Android NDK 28.2.13676358, CMake and Ninja, because the face
tracking package compiles an image library from source on the first build.

## Install

```yaml
dependencies:
  liveness_sdk:
    git:
      url: https://github.com/tulga-dev/liveness-sdk.git
      ref: stable
```

See [INTEGRATION.md](INTEGRATION.md) for the full backend and app integration, step by step.

- **iOS:** add `NSCameraUsageDescription` to `Info.plist`; deployment target 15.0 or later.
- **Android:** the `camera` plugin adds the camera permission; check the minimum SDK that
  `camera` and `face_detection_tflite` require.
- For testing against a plain `http://` server, allow cleartext traffic on Android
  (`android:usesCleartextTraffic="true"`) and add an ATS exception on iOS. Use HTTPS in production.

## Use

Your backend calls `POST /v1/sessions` on the liveness server and sends the app
`session_id`, `session_token` and `turns`.

```dart
final outcome = await Navigator.of(context).push<LivenessOutcome>(
  MaterialPageRoute(
    builder: (ctx) => LivenessCheck(
      serverUrl: 'https://liveness.example.mn',
      sessionId: sessionId,
      sessionToken: sessionToken,
      turns: turns,                       // e.g. ['left', 'up', 'right']
      strings: LivenessStrings.mn,        // or your own texts
      onDone: (o) => Navigator.of(ctx).pop(o),
    ),
  ),
);
if (outcome?.status == LivenessStatus.completed) {
  // Ask YOUR backend for the verdict; it calls GET /v1/sessions/{id}.
}
```

A failed or timed-out check uses up the session. To retry, have your backend create a new one.

## Test app

`example/` is a small app for trying the SDK on a phone. It needs the address of a liveness server
that has its test endpoints switched on, and the access code for them; no API key is in the app.

```sh
cd example
flutter create . --platforms=android,ios
flutter run --dart-define=SERVER=https://YOUR-LIVENESS-SERVER
```

## Directions

Left and right are handled for you on both platforms: iOS delivers front-camera frames mirrored,
and the SDK corrects for that itself (checked on a real iPhone). Leave `invertYaw` and `invertPitch`
at false; they exist only as an escape hatch for an unusual device.

## Things to check on real phones

- Taking a photo while the camera stream is running works on your target devices.
- Photos arrive upright on the server (they carry EXIF orientation, which the server honours).
- Cheap Android phones keep up; if not, lower the resolution preset.
- The Mongolian texts in `LivenessStrings.mn` read naturally.

## Licence

Proprietary. See [LICENSE](LICENSE). The SDK works only with a liveness server and an API key issued by us.
