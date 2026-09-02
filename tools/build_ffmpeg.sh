#!/usr/bin/env bash
#
# build_ffmpeg.sh — vendor a universal, LGPL FFmpeg for vdodtor.
#
# Why this exists: the M0 spike linked Homebrew's FFmpeg, which is built
# --enable-gpl and arm64-only. Neither is shippable. This produces
# universal (arm64 + x86_64) *shared* libraries with no GPL or nonfree
# components, which is what LGPL 2.1 dynamic linking requires.
#
# Output: third_party/ffmpeg/{include,lib,BUILD_INFO.txt}
# Idempotent: re-running with the output present is a no-op unless -f.
#
#   tools/build_ffmpeg.sh [-f]     -f forces a clean rebuild
#
set -euo pipefail

FFMPEG_VERSION="9.0.1"
FFMPEG_SHA256="cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635"
MACOS_MIN="11.0"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/third_party/ffmpeg"
WORK="$ROOT/third_party/.ffmpeg-build"
SRC="$WORK/ffmpeg-$FFMPEG_VERSION"

FORCE=0
[[ "${1:-}" == "-f" ]] && FORCE=1

if [[ $FORCE -eq 0 && -f "$OUT/BUILD_INFO.txt" ]] && grep -q "version: $FFMPEG_VERSION" "$OUT/BUILD_INFO.txt"; then
  echo "ffmpeg $FFMPEG_VERSION already vendored at $OUT (use -f to rebuild)"
  exit 0
fi

for tool in nasm pkg-config make clang lipo; do
  command -v "$tool" >/dev/null || { echo "missing required tool: $tool" >&2; exit 1; }
done

mkdir -p "$WORK"

# ---- fetch -----------------------------------------------------------------
TARBALL="$WORK/ffmpeg-$FFMPEG_VERSION.tar.xz"
if [[ ! -f "$TARBALL" ]]; then
  echo "==> fetching ffmpeg $FFMPEG_VERSION"
  curl -fL --retry 3 -o "$TARBALL" "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"
  curl -fL --retry 3 -o "$TARBALL.asc" "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz.asc" || true
fi
ACTUAL_SHA="$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)"
if [[ "$ACTUAL_SHA" != "$FFMPEG_SHA256" ]]; then
  echo "sha256 mismatch for $TARBALL" >&2
  echo "  expected $FFMPEG_SHA256" >&2
  echo "  actual   $ACTUAL_SHA" >&2
  exit 1
fi
echo "    sha256 ok: $ACTUAL_SHA"

rm -rf "$SRC"
tar -xf "$TARBALL" -C "$WORK"

# ---- configure -------------------------------------------------------------
# LGPL 2.1 only. No --enable-gpl, no --enable-nonfree, no --enable-version3.
# Shared libraries so the app links dynamically, which is the LGPL-clean path
# and lets a user substitute their own FFmpeg build.
COMMON_FLAGS=(
  --enable-shared
  --disable-static
  --disable-programs
  --disable-doc
  --disable-debug
  --disable-avdevice
  --disable-network
  --disable-devices
  --disable-sdl2
  --disable-xlib
  --disable-libxcb
  --disable-securetransport
  --enable-pthreads
  --enable-videotoolbox
  --enable-audiotoolbox
  --install-name-dir=@rpath
)

build_arch() {
  local arch="$1"
  local prefix="$WORK/install-$arch"
  if [[ $FORCE -eq 0 && -f "$prefix/lib/libavcodec.dylib" ]]; then
    echo "==> reusing existing $arch build at $prefix"
    return 0
  fi
  echo "==> configuring ffmpeg for $arch"
  rm -rf "$WORK/build-$arch" "$prefix"
  mkdir -p "$WORK/build-$arch"
  cd "$WORK/build-$arch"

  local -a extra=()
  if [[ "$arch" == "x86_64" && "$(uname -m)" != "x86_64" ]]; then
    extra+=(--enable-cross-compile --arch=x86_64 --cpu=x86-64 --target-os=darwin)
  fi

  "$SRC/configure" \
    --prefix="$prefix" \
    "${COMMON_FLAGS[@]}" \
    ${extra[@]+"${extra[@]}"} \
    --cc="clang -arch $arch" \
    --cxx="clang++ -arch $arch" \
    --host-cc=clang \
    --extra-cflags="-arch $arch -mmacosx-version-min=$MACOS_MIN" \
    --extra-ldflags="-arch $arch -mmacosx-version-min=$MACOS_MIN" \
    > "configure-$arch.log" 2>&1 || { tail -40 "configure-$arch.log"; echo "configure failed for $arch" >&2; exit 1; }

  # Fail loudly rather than shipping a licence violation.
  grep -q '^#define CONFIG_GPL 0$'     config.h || { echo "REFUSING: CONFIG_GPL is not 0 for $arch" >&2; exit 1; }
  grep -q '^#define CONFIG_NONFREE 0$' config.h || { echo "REFUSING: CONFIG_NONFREE is not 0 for $arch" >&2; exit 1; }
  grep -q '^#define CONFIG_VERSION3 0$' config.h || { echo "REFUSING: CONFIG_VERSION3 is not 0 for $arch" >&2; exit 1; }

  echo "==> building ffmpeg for $arch ($(sysctl -n hw.ncpu) jobs)"
  make -j"$(sysctl -n hw.ncpu)" > "make-$arch.log" 2>&1 || { tail -40 "make-$arch.log"; echo "make failed for $arch" >&2; exit 1; }
  make install > "install-$arch.log" 2>&1
}

build_arch arm64
build_arch x86_64

# ---- lipo into universal ---------------------------------------------------
echo "==> merging into universal binaries"
rm -rf "$OUT"
mkdir -p "$OUT/lib" "$OUT/include"
cp -R "$WORK/install-arm64/include/." "$OUT/include/"

# Each library is written out under the *exact* name its install_name refers
# to (libavcodec.63.dylib, not libavcodec.63.1.101.dylib), so the set that gets
# embedded in the app bundle is real files with no symlinks to chase. The
# unversioned name is then symlinked for the linker's -lavcodec.
for dylib in "$WORK/install-arm64/lib"/*.dylib; do
  [[ -L "$dylib" ]] && continue
  real="$(basename "$dylib")"
  soname="$(basename "$(otool -D "$dylib" | tail -1)")"   # e.g. libavcodec.63.dylib
  lipo -create "$dylib" "$WORK/install-x86_64/lib/$real" -output "$OUT/lib/$soname"
  # Ad-hoc sign the universal file, and not for tidiness: on Apple Silicon the
  # linker ad-hoc signs the arm64 slice it produces and leaves the cross-built
  # x86_64 one bare, so `lipo -create` yields a binary that `codesign -dvv`
  # calls signed — it reports the native slice — and that `codesign --sign`
  # refuses as "code object is not signed at all" when it recurses into a
  # framework containing it. That failure surfaces at the *app's* signing step,
  # naming the framework rather than the library, and it makes a release build
  # unsignable while every debug run works.
  codesign --force --sign - --timestamp=none "$OUT/lib/$soname"
  # libavcodec.63.dylib -> libavcodec.dylib
  unversioned="${soname%%.*}.dylib"
  [[ "$unversioned" != "$soname" ]] && ln -sf "$soname" "$OUT/lib/$unversioned"
done
cp -R "$WORK/install-arm64/lib/pkgconfig" "$OUT/lib/" 2>/dev/null || true

# ---- record + verify -------------------------------------------------------
cp "$SRC/COPYING.LGPLv2.1" "$OUT/COPYING.LGPLv2.1"
cp "$SRC/CREDITS" "$OUT/CREDITS" 2>/dev/null || true

{
  echo "version: $FFMPEG_VERSION"
  echo "source:  https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"
  echo "sha256:  $ACTUAL_SHA"
  echo "licence: LGPL v2.1 or later (CONFIG_GPL=0, CONFIG_NONFREE=0, CONFIG_VERSION3=0)"
  echo "arches:  arm64 x86_64 (universal)"
  echo "macos:   min $MACOS_MIN"
  echo "built:   by tools/build_ffmpeg.sh"
  echo
  echo "configure flags:"
  printf '  %s\n' "${COMMON_FLAGS[@]}"
} > "$OUT/BUILD_INFO.txt"

echo "==> verifying"
for dylib in "$OUT"/lib/*.dylib; do
  [[ -L "$dylib" ]] && continue
  archs="$(lipo -archs "$dylib")"
  [[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || { echo "not universal: $dylib ($archs)" >&2; exit 1; }
  otool -D "$dylib" | tail -1 | grep -q '@rpath/' || { echo "install_name is not @rpath: $dylib" >&2; exit 1; }
  # Every slice, not just the one this machine runs. A dylib whose x86_64 half
  # is unsigned is the failure described above, and it is invisible to the
  # unqualified `codesign -dvv`.
  for arch in arm64 x86_64; do
    codesign --verify --arch "$arch" "$dylib" 2>/dev/null ||
      { echo "$arch slice of $dylib is not signed" >&2; exit 1; }
  done
done

echo
echo "vendored ffmpeg $FFMPEG_VERSION -> $OUT"
lipo -archs "$OUT/lib/libavcodec.dylib" 2>/dev/null || true
du -sh "$OUT"
