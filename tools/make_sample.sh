#!/usr/bin/env bash
# Writes the footage the sample project is cut from into app/assets/sample.
#
# Generated rather than vendored, for the reason tools/make_luts.dart gives
# about the looks: what ships inside a product sold without an account has to
# be something we may sell, and stock footage almost never is. Twenty lines of
# ffmpeg is also a thing a reviewer can argue with, where a licence for a
# clip of a beach is a thing they have to take on trust.
#
# The files are committed — a first launch must not need a build step — and
# they are small enough for that to be reasonable: a gradient is the most
# compressible picture there is, which is the other half of why these are
# gradients. Swapping in real footage later is a change to this file and to
# the names in app/lib/media/sample_project.dart, and to nothing else.
#
# Requires an ffmpeg CLI on PATH: the vendored build ships libraries only,
# exactly as engine/tests/media/generate.sh already assumes.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

out="app/assets/sample"
mkdir -p "$out"
common="-y -loglevel error"

# 720p rather than 1080p. The sample is a demonstration of the editor and not
# of anybody's bitrate, the project it lands in is 1080p so it is scaled up by
# the compositor either way, and the whole of it has to fit in a disk image
# people download over hotel wifi.
size=1280x720
rate=30
secs=5

# Three shots that grade well. A gradient has a shadow end and a highlight end
# and nothing in between to distract from what a look does to them, which is
# what makes a split-tone visible on first run rather than subtle.
#
# `speed` is deliberately tiny: this is a backdrop, and a sample project whose
# footage is busier than the captions over it is a demonstration of the wrong
# thing.
ffmpeg $common -f lavfi -i \
  "gradients=size=$size:rate=$rate:duration=$secs:type=linear:speed=0.012:\
c0=0x2B0B3F:c1=0xC2185B:c2=0xFF8A3D:c3=0xFFD166:nb_colors=4:x0=0:y0=0:x1=1280:y1=720" \
  -c:v libx264 -preset slow -crf 24 -pix_fmt yuv420p -profile:v high \
  -colorspace bt709 -color_primaries bt709 -color_trc bt709 -an \
  "$out/sunrise.mp4"

ffmpeg $common -f lavfi -i \
  "gradients=size=$size:rate=$rate:duration=$secs:type=linear:speed=0.010:\
c0=0x02222A:c1=0x0E7C7B:c2=0x17BEBB:c3=0xD4F1F4:nb_colors=4:x0=0:y0=720:x1=1280:y1=0" \
  -c:v libx264 -preset slow -crf 24 -pix_fmt yuv420p -profile:v high \
  -colorspace bt709 -color_primaries bt709 -color_trc bt709 -an \
  "$out/tide.mp4"

ffmpeg $common -f lavfi -i \
  "gradients=size=$size:rate=$rate:duration=$secs:type=spiral:speed=0.008:\
c0=0x080B1A:c1=0x1B2A6B:c2=0x5C3C92:c3=0xE8735A:nb_colors=4:x0=200:y0=180:x1=1080:y1=540" \
  -c:v libx264 -preset slow -crf 24 -pix_fmt yuv420p -profile:v high \
  -colorspace bt709 -color_primaries bt709 -color_trc bt709 -an \
  "$out/dusk.mp4"

# A bed, so the audio lane has something on it: the waveform, the fade handles
# and the volume line are a third of the editor and all three are invisible on
# a silent timeline.
#
# A minor ninth chord held under a slow tremolo rather than a sine, because a
# single tone at a fixed level is the sound of a hearing test and somebody has
# to listen to this within a minute of installing. Amplitudes fall with
# frequency for the same reason a mix does; the total stays under 0.5 so the
# clip has headroom for the volume line to be dragged *up* as well as down.
#
# The 40 ms ramps at each end are the file's own, and are not the point: the
# sample project draws real fades on the clip, which is what is being shown.
# These only stop the source itself clicking if somebody trims past them.
ffmpeg $common -f lavfi -i \
  "aevalsrc=exprs='(0.22*sin(2*PI*220*t)+0.15*sin(2*PI*261.63*t)\
+0.10*sin(2*PI*329.63*t)+0.06*sin(2*PI*493.88*t))*(0.82+0.18*sin(2*PI*0.16*t))\
|(0.22*sin(2*PI*220*t)+0.15*sin(2*PI*261.63*t)+0.10*sin(2*PI*329.63*t)\
+0.06*sin(2*PI*493.88*t))*(0.82+0.18*sin(2*PI*0.19*t))':s=48000:d=15:c=stereo" \
  -af "afade=t=in:st=0:d=0.04,afade=t=out:st=14.96:d=0.04" \
  -c:a aac -b:a 128k "$out/chord-bed.m4a"

ls -l "$out"
