# Liveness check: integration guide

For developers adding the liveness check to a Flutter app and its backend.

**Status: pilot.** Please report anything that fails. Use the `stable` branch unless we have
agreed otherwise.

## What you receive

| Item | Value |
| --- | --- |
| API address | sent to you together with your keys. Shown below as `https://YOUR-LIVENESS-SERVER` |
| Test API key | starts with `lv_test_`. Free. Use it for all development. |
| Live API key | starts with `lv_live_`. Billed. Sent after your tests pass. |
| SDK | this repository |

**The API key belongs on your server only.** Never put it in the mobile app, in the app's
source code or in a request the phone makes.

## How one check works

```
Your backend                    Your app (SDK)                 Liveness API
     |  1. POST /v1/sessions  --------------------------------------> |
     |  <-- session_id, session_token, turns ------------------------ |
     |  2. give those three values to the app                         |
     |  ------------------------> |                                   |
     |                            |  3. photos uploaded by the SDK -> |
     |  <-- "completed" --------- |                                   |
     |  4. GET /v1/sessions/{id}  ----------------------------------> |
     |  <-- live / not_live, face match score, front photo ---------- |
```

The phone is only ever told "completed". The verdict travels from server to server, so it
cannot be changed on the device. Decide what the customer may do next from step 4, never
from what the app reports.

## Step 1. Backend: start a check

Send the customer's reference photo (for example the one you fetched from the state
registry) so the live face is matched against it.

```sh
curl -X POST https://YOUR-LIVENESS-SERVER/v1/sessions \
  -H "X-API-Key: $LIVENESS_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"reference_photo\": \"$(base64 -w0 reference.jpg)\"}"
```

Response, HTTP 201:

```json
{
  "session_id": "6f1c…",
  "session_token": "pV3x…",
  "turns": ["left", "up", "right"],
  "expires_in_s": 40,
  "face_match": true
}
```

- The reference photo is a JPEG, at most 1.5 MB, with exactly one face.
- Without a body the check still runs, but only liveness is decided, not identity.
- The session expires `expires_in_s` seconds after this call. Create it at the moment the
  customer opens the liveness screen, not earlier.
- One session is one attempt. For a retry, create a new session.

## Step 2. App: add the SDK

`pubspec.yaml`:

```yaml
dependencies:
  liveness_sdk:
    git:
      url: https://github.com/tulga-dev/liveness-sdk.git
      ref: stable
```

- **Android:** building needs the Android NDK 28.2.13676358, CMake and Ninja, because the
  face tracking package compiles an image library on the first build.
- **iOS:** add `NSCameraUsageDescription` to `Info.plist`. Deployment target 15.0 or later.

## Step 3. App: show the liveness screen

Your app asks your backend for a session (step 1), then:

```dart
import 'package:liveness_sdk/liveness_sdk.dart';

final outcome = await Navigator.of(context).push<LivenessOutcome>(
  MaterialPageRoute(
    builder: (ctx) => LivenessCheck(
      serverUrl: 'https://YOUR-LIVENESS-SERVER',
      sessionId: sessionId,          // from your backend
      sessionToken: sessionToken,    // from your backend
      turns: turns,                  // from your backend, e.g. ['left', 'up', 'right']
      timeLimitSeconds: expiresInS - 3,
      strings: LivenessStrings.mn,   // Mongolian prompts; omit for English
      onDone: (o) => Navigator.of(ctx).pop(o),
    ),
  ),
);

switch (outcome?.status) {
  case LivenessStatus.completed:
    // Photos are uploaded. Ask YOUR backend for the verdict (step 4).
    break;
  case LivenessStatus.timedOut:     // the customer ran out of time: offer a retry
  case LivenessStatus.cameraError:  // no camera permission or no front camera
  case LivenessStatus.uploadError:  // network problem, or the session expired
  case null:                        // the customer pressed back
    break;
}
```

The screen shows the face in a circle. For each step it shows which way to turn and takes
the photo automatically. If a pose is not recognised within 6 seconds a "take photo"
button appears; the server still decides.

## Step 4. Backend: read the verdict

```sh
curl https://YOUR-LIVENESS-SERVER/v1/sessions/$SESSION_ID \
  -H "X-API-Key: $LIVENESS_API_KEY"
```

```json
{
  "session_id": "6f1c…",
  "status": "live",
  "reason": "ok",
  "mode": "test",
  "face_match_score": 0.71,
  "face_match_threshold": 0.363,
  "front_photo_jpeg_base64": "…"
}
```

`status` is `pending`, `processing`, `live` or `not_live`. With a reference photo, `live`
means both: a live person, and the same person as the reference photo.

**The front photo is returned once**, on the first read of a `live` result, and only within
15 minutes of the check. Save it to your own KYC file on that first read. We do not keep
photos.

| `reason` | Meaning | What to tell the customer |
| --- | --- | --- |
| `ok` | Passed | |
| `expired` | Photos arrived too late | Try again |
| `no_face`, `multiple_faces` | A photo had no face, or more than one | Be alone, in good light |
| `front_not_straight` | First photo was not straight on | Look straight at the camera |
| `turn_not_matched:<turn>` | A head turn was too small or the wrong way | Turn further |
| `flat_face` | The face looked like a flat photo or screen | Try again; repeated failures are suspicious |
| `motion_not_continuous:<turn>` | The head was not seen moving through the turn (SDK versions with the motion check) | Turn smoothly; repeated failures are suspicious |
| `face_changed` | Different people in the four photos | Suspicious |
| `face_mismatch` | Live face does not match the reference photo | Suspicious, or a poor reference photo |
| `internal_error` | A failure on our side. Not billed | Try again |

## Errors

| HTTP | `error` | Meaning |
| --- | --- | --- |
| 401 | `bad_api_key` | Key missing, wrong or revoked |
| 403 | `client_suspended` | Your account is suspended. Contact us |
| 429 | `rate_limited` | More than 120 new sessions in a minute |
| 400 | `reference_no_single_face` | The reference photo has no face, or several |
| 400 | `reference_unreadable`, `bad_request` | The photo or the JSON could not be read |
| 413 | `too_large` | Photo over 1.5 MB |
| 404 | `not_found` | No such session for your account |

## Billing and usage

One charge per check that reaches a verdict (`live` or `not_live`) with a **live** key.
Not charged: checks with a test key, sessions never uploaded, expired sessions and
`internal_error`.

```sh
curl "https://YOUR-LIVENESS-SERVER/v1/usage?month=2026-11" \
  -H "X-API-Key: $LIVENESS_API_KEY"
```

```json
{"month": "2026-11", "billable_checks": 132, "live": 118, "not_live": 14, "test_checks": 57}
```

## What to test before going live

1. A genuine customer passes, on several phones, in normal indoor light.
2. Someone else's reference photo is rejected (`face_mismatch`).
3. A photo of a face held to the camera is rejected.
4. No camera permission, no network, and pressing back are all handled in your app.
5. Your backend, not the app, decides what happens after the check.

## Limits you should know

- Not certified. Do not describe it as ISO/IEC 30107-3 compliant.
- Treat the result as one signal in your KYC decision, not the only one. Ask us for the current
  security notes before you go live.
- Photos are processed on servers outside Mongolia and are not stored. Confirm with your
  compliance team that this fits your obligations.
