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

# Four solid quadrants, and the same bitstream carrying a display matrix. The
# pair is what pins the *direction* of a rotation: a quarter turn the wrong way
# is still a quarter turn, and on a symmetrical fixture it looks identical.
# Copying the stream rather than re-encoding is deliberate — the two files are
# the same pixels, so a test comparing them is testing the metadata alone.
ffmpeg $common -f lavfi -i "color=c=0xC00000:s=160x120:r=30:d=1" \
  -f lavfi -i "color=c=0x00C000:s=160x120:r=30:d=1" \
  -f lavfi -i "color=c=0x0000C0:s=160x120:r=30:d=1" \
  -f lavfi -i "color=c=0xC0C000:s=160x120:r=30:d=1" \
  -filter_complex "[0][1]hstack[t];[2][3]hstack[b];[t][b]vstack[v]" -map "[v]" \
  -c:v libx264 -preset veryfast -crf 18 -pix_fmt yuv420p -an quadrants.mp4
ffmpeg $common -display_rotation -90 -i quadrants.mp4 -c copy quadrants_cw90.mp4

# Non-square pixels. Coded 160x240 with a sample aspect of 2:1, so it displays
# 320x240 — anything that fits it from its coded size draws it half as wide as
# it should be, which is what DVD-era and some phone footage looks like.
ffmpeg $common -f lavfi -i "color=c=0x00C864:size=160x240:rate=30:duration=1" \
  -vf setsar=2/1 -c:v libx264 -preset veryfast -crf 18 -pix_fmt yuv420p \
  -an anamorphic_sar2.mp4

# Irregular timestamps: r_frame_rate and avg_frame_rate diverge. Selecting
# every third frame of 60 fps makes the *heuristic* fire, which is what this
# file is for — the timestamps that come out are perfectly regular 20 fps.
ffmpeg $common -f lavfi -i "testsrc2=size=320x240:rate=60:duration=2" \
  -vf "select='not(mod(n,3))'" -fps_mode vfr \
  -c:v libx264 -preset veryfast -crf 40 -pix_fmt yuv420p -an vfr.mp4

# Timestamps that really are irregular: bursts of frames a sixtieth apart
# separated by holds of half a second, which is the shape adaptive-rate phone
# capture produces in changing light. `passthrough` keeps the selected frames'
# original presentation times instead of restamping them onto a cadence.
#
# The frames land on the 60 fps grid at n = 0 1 2 30 31 60 90 91 92 93 119, so
# every one is a round number of project ticks. Two things about the file are
# worth knowing before reading a test against it: the per-frame durations the
# muxer writes are in *decode* order, so with B-frames they land on the wrong
# frames and cannot be trusted, and the last frame is held to the end of the
# stream rather than for the sixtieth it claims.
ffmpeg $common -f lavfi -i "testsrc2=size=320x240:rate=60:duration=2" \
  -vf "select='eq(n,0)+eq(n,1)+eq(n,2)+eq(n,30)+eq(n,31)+eq(n,60)+eq(n,90)+eq(n,91)+eq(n,92)+eq(n,93)+eq(n,119)'" \
  -fps_mode passthrough -c:v libx264 -preset veryfast -crf 40 -pix_fmt yuv420p \
  -an vfr_bursts.mp4

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

# --- stickers ---------------------------------------------------------------
# Animated overlays, which the engine decodes whole rather than seeking in.
# Built from PNG frames through the image2 and concat demuxers because that is
# the only way to say exactly how long each frame is on screen — and how long
# each frame is on screen is the whole thing the sticker path has to get right.
#
# A tiny palette rather than the default: four solid colours need eight
# entries, and the 256-entry table ffmpeg writes per frame otherwise makes a
# 1 KB fixture 40 KB.
mkdir -p .sticker_frames
i=1
for c in 0xC00000 0x00C000 0x0000C0 0xC0C000; do
  ffmpeg $common -f lavfi -i "color=c=$c:size=16x16:d=1" -frames:v 1 \
    ".sticker_frames/f$i.png"
  i=$((i + 1))
done
# One palette for the whole animation — `stats_mode=full`, which is the
# default — because a per-frame palette written to a single file leaves only
# the last frame's colours and maps every frame onto them.
ffmpeg $common -framerate 4 -i .sticker_frames/f%d.png \
  -vf "palettegen=max_colors=8" -update 1 .sticker_frames/pal.png

# Four frames, a quarter of a second each: red, green, blue, yellow.
ffmpeg $common -framerate 4 -i .sticker_frames/f%d.png -i .sticker_frames/pal.png \
  -lavfi "paletteuse" -loop 0 sticker_4up.gif

# The same four colours with delays of 0.5, 0.25, 0.25 and whatever the muxer
# gives the last one. This is the fixture that tells indexing by *time* apart
# from indexing by frame number: at 0.4 s a sticker read at its nominal 4 fps
# would be showing green, and this one is still red.
{
  echo "file 'f1.png'"; echo "duration 0.5"
  echo "file 'f2.png'"; echo "duration 0.25"
  echo "file 'f3.png'"; echo "duration 0.25"
  echo "file 'f4.png'"
} > .sticker_frames/uneven.txt
ffmpeg $common -f concat -safe 0 -i .sticker_frames/uneven.txt \
  -i .sticker_frames/pal.png -lavfi "paletteuse" -fps_mode vfr -loop 0 \
  sticker_uneven.gif

# An APNG with a real alpha channel — a red then a green square inside a
# transparent border. GIF has one transparent colour and no partial alpha, so
# it cannot be the fixture that checks a sticker composites over the picture
# instead of over a black square.
i=1
for c in 0xC00000 0x00C000; do
  ffmpeg $common -f lavfi -i "color=c=$c:size=8x8:d=1" -frames:v 1 \
    -vf "format=rgba,pad=16:16:4:4:color=0x00000000@0x0" ".sticker_frames/a$i.png"
  i=$((i + 1))
done
ffmpeg $common -framerate 2 -i .sticker_frames/a%d.png -plays 0 -f apng \
  sticker_alpha.apng

rm -rf .sticker_frames
