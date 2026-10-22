# ARM Link 1.0

An iOS WKWebView app for the private ARM Link website. iPhone and desktop use the **same ChatGPT account** and share six-axis poses, saved steps and playback through the site's per-user D1 state. This app is separate from Codex Island, despite sharing this repository.

Website: https://arduino-arm-3d-viewer.freshauk74.chatgpt.site/

## Use

1. Sideload the unsigned IPA after signing it using your own signing tool.
2. Open ARM Link and complete the website's ChatGPT sign-in. The website remains owner-private.
3. Open the website on a computer and sign into the same account.
4. Move sliders on either device; both show the same arm. Save poses and press Play. Stop holds the current interpolated pose; Reset returns to the initial pose; Clear removes saved steps.

The app displays the actual website and controls; it is not an Arduino emulator and does not run the tutorial's `.ino` code. It requires internet. The app uses the persistent WebKit cookie store, never embeds service credentials, and has no hardcoded private access token. Login must be completed by the user on-device. Compilation does not verify account login on a physical phone.

## Motors

| Joint | Planned motor |
|---|---|
| Waist / shoulder / elbow | MG996R × 3 |
| Wrist roll / wrist pitch / gripper | SG90 × 3 |

Angles are **model angles**, not calibrated servo pulse targets. Physical calibration and Arduino transport are future work. The 3D model is an approximate concept model.

## Sync protocol

Same-origin `GET /api/arm` returns `{state, revision, serverTime}`. POST accepts one JSON command: `axis` (axis 0…5 and value), `save`, `play`, `stop`, `reset`, `clear`, or `speed` (10…180 model degrees/s). Only authenticated Sites identity can access that user's state. Reads poll every 500ms while visible; updates are queued and coalesced, with optimistic revision checks on the server. Playback uses a shared server timestamp, so it is animated locally rather than uploading every frame. Network latency affects response time; this is not hard realtime.

## Build

GitHub Actions workflow **Build ARM Link IPA** automatically builds on changes to `arm-link-ios/**` or its workflow. Artifacts contain `ArmLink-unsigned.ipa`. No Apple password/certificate is needed to compile; the unsigned IPA must be signed before installation.

Local Mac: install XcodeGen, run `xcodegen generate --spec arm-link-ios/project.yml --project arm-link-ios`, then open the generated Xcode project. Requires iOS 16+.
