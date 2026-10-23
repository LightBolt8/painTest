# painTest

iPhone app that estimates facial pain from a photo using OpenFace Action Units (estimated PSPI 0–16). Optional age entry and de-aging before scoring, because wrinkles on older faces can get mixed up with pain.

**Not a medical device.** Not a diagnosis. A personal pain log.

[GitHub Page](https://lightbolt8.github.io/painTest/)

## What it does

- Guided camera (face oval, yaw / quality hints), then review / retake
- OpenFace on your Mac (same Wi-Fi or a tunnel)
- Estimated PSPI, Action Unit list, 0–10 self-report, history, trends, CSV export
- Optional: type your age and de-age toward a target (default 25) before OpenFace

## Repo layout

- `painTest/` — SwiftUI app
- `scripts/` — Python OpenFace bridge (`openface_server.py`, age estimate, de-age)
- `docs/` — GitHub Pages site

OpenFace and FaceFusion installs are **not** in this repo (too large). You need those on the Mac separately.

## Run

1. Open `painTest.xcodeproj` in Xcode, run on an iPhone.
2. On the Mac: `python3 scripts/openface_server.py` (OpenFace built under `OpenFace/`).
3. Same Wi-Fi: the app finds the bridge. Away from home: paste the tunnel URL in Settings.
