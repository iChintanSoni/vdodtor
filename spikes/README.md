# M0 spikes

Throwaway code that answers the M0 questions in [../PLAN.md](../PLAN.md).
Findings live in [../docs/spike-notes.md](../docs/spike-notes.md). **Do not build on this** —
M1 starts a clean tree under `app/` and `engine/`.

Both spikes were built and measured on macOS 26.6 / Apple M3 Pro / Flutter 3.47.

## s1_preview — decode → composite → Flutter texture

Requires Homebrew FFmpeg (`brew install ffmpeg`) at `/opt/homebrew/opt/ffmpeg`.

```sh
cd s1_preview
flutter pub get
flutter run --release                      # interactive: transport, layers, live stats

# benchmark. VD_TICKER=1 is required for the ui-fps column to mean anything, and the
# window must stay frontmost — Flutter stops rendering entirely when occluded.
flutter build macos --release
VD_BENCH=1 VD_TICKER=1 ./build/macos/Build/Products/Release/s1_preview.app/Contents/MacOS/s1_preview
```

Test clips are generated, not committed:

```sh
mkdir -p media && cd media
ffmpeg -f lavfi -i testsrc2=size=3840x2160:rate=60:duration=20 -c:v h264_videotoolbox -b:v 40M -pix_fmt yuv420p 4k60_h264.mp4
ffmpeg -f lavfi -i testsrc2=size=3840x2160:rate=60:duration=20 -c:v hevc_videotoolbox -b:v 25M -tag:v hvc1 -pix_fmt yuv420p 4k60_hevc.mp4
ffmpeg -f lavfi -i testsrc2=size=1920x1080:rate=60:duration=20 -c:v h264_videotoolbox -b:v 12M -pix_fmt yuv420p 1080p60_h264.mp4
```

## s2_timeline — canvas timeline

```sh
cd s2_timeline
flutter run --release      # drag to move · drag ends to trim · S split · Del ripple-delete
                           # N toggle snap · ⌘-scroll zoom

flutter build macos --release
VD_BENCH=1 ./build/macos/Build/Products/Release/s2_timeline.app/Contents/MacOS/s2_timeline
```

The benchmark also writes `s2_timeline_render.png`, a direct render of the painter.
