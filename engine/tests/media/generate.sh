#!/usr/bin/env bash
# Regenerates the engine's probe fixtures. They are committed (a few KB each)
# so `ctest` needs no media generation step and CI stays hermetic.
# Requires an ffmpeg CLI on PATH — the vendored build ships libraries only.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

common="-y -loglevel error"

# Constant 30 fps, stereo AAC, square pixels.
ffmpeg $common -f lavfi -i "testsrc2=size=320x240:rate=30:duration=2" \
  -f lavfi -i "sine=frequency=440:duration=2:sample_rate=48000" \
  -ac 2 -c:v libx264 -preset veryfast -crf 40 -pix_fmt yuv420p \
  -c:a aac -b:a 32k cfr_30fps_stereo.mp4

# Same, carrying a display matrix. -display_rotation takes a COUNTER-clockwise
# angle, so -90 there is the 90-degrees-clockwise-to-display case the probe
# reports as rotation_degrees == 90.
ffmpeg $common -f lavfi -i "testsrc2=size=320x240:rate=30:duration=1" \
  -c:v libx264 -preset veryfast -crf 40 -pix_fmt yuv420p -an rotated_tmp.mp4
ffmpeg $common -display_rotation -90 -i rotated_tmp.mp4 -c copy rotated_cw90.mp4
rm -f rotated_tmp.mp4

# Audio only, mono, 44.1 kHz.
ffmpeg $common -f lavfi -i "sine=frequency=220:duration=3:sample_rate=44100" \
  -ac 1 -c:a aac -b:a 32k audio_only.m4a

# Three seconds in three amplitudes, for the peak analyser: a second of
# silence, a second at 0.25 on both channels, and a second at 0.9 on the LEFT
# only. Built with aevalsrc rather than sine because the amplitudes have to be
# exact — `sine` peaks at 0.125 and converting it from mono costs another 3 dB,
# so a fixture built that way tests a level nobody chose. The last second is
# the interesting one: it is the case that tells a waveform taken across both
# channels apart from one taken over their average, which would draw it at half
# the height it should be.
ffmpeg $common -f lavfi \
  -i 'aevalsrc=exprs=0.25*sin(2*PI*440*t)*between(t\,1\,2)+0.9*sin(2*PI*440*t)*between(t\,2\,3)|0.25*sin(2*PI*440*t)*between(t\,1\,2):s=48000:d=3:c=stereo' \
  -c:a aac -b:a 128k audio_steps.m4a

# Irregular timestamps: r_frame_rate and avg_frame_rate diverge.
ffmpeg $common -f lavfi -i "testsrc2=size=320x240:rate=60:duration=2" \
  -vf "select='not(mod(n,3))'" -fps_mode vfr \
  -c:v libx264 -preset veryfast -crf 40 -pix_fmt yuv420p -an vfr.mp4

# Flat colour for the compositor's YCbCr conversion. 0x00C864 is chosen
# deliberately: BT.601 and BT.709 disagree about it loudly — decoding this file
# with the wrong matrix moves green by about 25 counts — where for most colours
# the two differ by only a few, which is what makes a wrong matrix so easy to
# ship. One file is SD and untagged, exercising the fallback; one is HD and
# explicitly tagged BT.709.
ffmpeg $common -f lavfi -i "color=c=0x00C864:size=320x240:rate=30:duration=1" \
  -c:v libx264 -preset veryfast -crf 18 -pix_fmt yuv420p -an solid_sd_601.mp4

ffmpeg $common -f lavfi -i "color=c=0x00C864:size=1280x720:rate=30:duration=1" \
  -c:v libx264 -preset veryfast -crf 18 -pix_fmt yuv420p \
  -colorspace bt709 -color_primaries bt709 -color_trc bt709 -an solid_hd_709.mp4

# A second flat colour, so a timeline test can tell which clip is on screen
# from the pixels rather than from a frame count.
ffmpeg $common -f lavfi -i "color=c=0xC86400:size=320x240:rate=30:duration=1" \
  -c:v libx264 -preset veryfast -crf 18 -pix_fmt yuv420p -an solid_sd_orange.mp4

# Not media at all, for the failure path.
printf 'this is not a video\n' > not_media.txt

ls -la
