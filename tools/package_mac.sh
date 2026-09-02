#!/usr/bin/env bash
#
# package_mac.sh — build, sign, notarize and stamp vdodtor into a DMG.
#
#   tools/package_mac.sh --identity "Developer ID Application: … (TEAMID)" \
#                        --profile vdodtor
#   tools/package_mac.sh --adhoc          # a disk image to look at, not to ship
#
# Options
#   --identity <name>   Developer ID Application identity, or $VDODTOR_SIGN_IDENTITY
#   --profile <name>    notarytool keychain profile, or $VDODTOR_NOTARY_PROFILE
#                       (create one: xcrun notarytool store-credentials)
#   --adhoc             sign ad hoc; implies --skip-notarize
#   --skip-notarize     sign for real, stop before submitting
#   --allow-development-key  package even though the build trusts the licence
#                       key this repository carries the private half of
#   --out <dir>         where the DMG lands (default build/release)
#
# **Why signing is a script and not a checklist.** Three of the steps below are
# things a human forgets exactly once: signing the nested FFmpeg dylibs before
# the framework that contains them (sign them after and the framework's seal is
# already broken), giving the outer app the entitlements and the inner code
# none, and checking that what got embedded is what the licence notice claims
# got embedded. All three fail late — at a user's Gatekeeper prompt, or in a
# licence obligation nobody re-reads — so they are here rather than in a
# document.
#
# It refuses more than it does. A stale third-party notice, a dylib that is not
# the one we vendored, a build that still trusts the development licence key:
# each stops the run, because every one of them is only discoverable after the
# DMG is in somebody's hands.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT/app"
FFMPEG_LIB="$ROOT/third_party/ffmpeg/lib"

IDENTITY="${VDODTOR_SIGN_IDENTITY:-}"
PROFILE="${VDODTOR_NOTARY_PROFILE:-}"
OUT="$ROOT/build/release"
ADHOC=0
NOTARIZE=1
ALLOW_DEV_KEY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --identity) IDENTITY="$2"; shift 2 ;;
    --profile)  PROFILE="$2";  shift 2 ;;
    --out)      OUT="$2";      shift 2 ;;
    --adhoc)    ADHOC=1; NOTARIZE=0; shift ;;
    --skip-notarize) NOTARIZE=0; shift ;;
    --allow-development-key) ALLOW_DEV_KEY=1; shift ;;
    -h|--help) sed -n '3,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

die() { echo "error: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

[[ "$(uname -s)" == "Darwin" ]] || die "macOS only"

# ---- preflight -------------------------------------------------------------
step "preflight"

for tool in flutter dart xcrun hdiutil codesign shasum; do
  command -v "$tool" >/dev/null || die "missing required tool: $tool"
done

[[ -f "$FFMPEG_LIB/libavcodec.dylib" ]] ||
  die "no vendored FFmpeg. Run tools/build_ffmpeg.sh."

# The one licence check that belongs in a *packaging* script. A shipped build
# trusting the key whose private half is in this repository hands Pro to
# anybody who reads GitHub — the first item under Packaging in PLAN.md — and
# the moment that stops being catchable is the moment a DMG exists.
if grep -q 'const String vdodtorSigningKey = _developmentSigningKey;' \
     "$APP_DIR/lib/pro/licence.dart"; then
  if [[ $ALLOW_DEV_KEY -eq 0 ]]; then
    die "this build trusts the development licence signing key.
  Replace vdodtorSigningKey in app/lib/pro/licence.dart, re-sign the shipped
  content packs against it (see CLAUDE.md), and package again.
  For a build nobody will be given: --allow-development-key"
  fi
  echo "    WARNING: packaging a build that trusts the development licence key"
fi

if [[ $ADHOC -eq 0 ]]; then
  [[ -n "$IDENTITY" ]] ||
    die "no signing identity. Pass --identity, set VDODTOR_SIGN_IDENTITY,
  or use --adhoc for a build nobody will be given."
  security find-identity -v -p codesigning | grep -qF "$IDENTITY" ||
    die "no codesigning identity matching \"$IDENTITY\" in the keychain"
  [[ "$IDENTITY" == "Developer ID Application:"* ]] ||
    echo "    WARNING: \"$IDENTITY\" is not a Developer ID; it will not notarize"
fi

if [[ $NOTARIZE -eq 1 && -z "$PROFILE" ]]; then
  die "no notarytool profile. Pass --profile, set VDODTOR_NOTARY_PROFILE,
  or use --skip-notarize."
fi

# The notice has to describe the libraries this DMG actually carries. It is
# generated from them, so regenerating and finding a difference means somebody
# re-vendored FFmpeg and did not re-run the generator.
step "checking the third-party notice is current"
NOTICES="$APP_DIR/assets/notices/THIRD_PARTY_NOTICES.md"
BEFORE="$(shasum -a 256 "$NOTICES" | cut -d' ' -f1)"
(cd "$ROOT" && dart run tools/make_notices.dart >/dev/null)
AFTER="$(shasum -a 256 "$NOTICES" | cut -d' ' -f1)"
[[ "$BEFORE" == "$AFTER" ]] ||
  die "assets/notices was out of date and has just been regenerated.
  Commit the change and package again — a DMG must not ship a licence notice
  that describes libraries it is not carrying."

VERSION="$(sed -n 's/^version:[[:space:]]*\([^+]*\).*/\1/p' "$APP_DIR/pubspec.yaml" | tr -d ' ')"
[[ -n "$VERSION" ]] || die "no version: line in app/pubspec.yaml"
echo "    vdodtor $VERSION"

# ---- build -----------------------------------------------------------------
step "building"
(cd "$APP_DIR" && flutter build macos --release)

APP="$APP_DIR/build/macos/Build/Products/Release/vdodtor.app"
[[ -d "$APP" ]] || die "no app at $APP"

# ---- what actually got embedded --------------------------------------------
#
# The notice states a version and a checksum for the FFmpeg *source*, and names
# the libraries built from it. This is the step that makes those sentences true
# of the bundle rather than of the repository: every dylib inside the app has
# to be byte for byte the one tools/build_ffmpeg.sh produced, and every one it
# produced has to be inside.
step "checking the embedded libraries are the vendored ones"
EMBEDDED_DIR="$APP/Contents/Frameworks/vdodtor_engine.framework/Versions/A/Frameworks"
[[ -d "$EMBEDDED_DIR" ]] || die "no embedded Frameworks folder at $EMBEDDED_DIR"

for lib in "$FFMPEG_LIB"/*.dylib; do
  [[ -L "$lib" ]] && continue        # linker symlinks; nothing loads these
  name="$(basename "$lib")"
  embedded="$EMBEDDED_DIR/$name"
  [[ -f "$embedded" ]] || die "$name was vendored but is not in the bundle"
  # Compared on LC_UUID, one per slice, and not on the file: this thing is
  # signed three times on its way here — by build_ffmpeg.sh, by the pod's embed
  # phase, and by the signing step below — and every signature changes the
  # bytes and the cdhash while the code stays identical. The UUID is what the
  # linker stamped in, so it survives all of that and still differs for any
  # different build.
  a="$(dwarfdump --uuid "$lib" | awk '{print $2, $3}' | sort)"
  b="$(dwarfdump --uuid "$embedded" | awk '{print $2, $3}' | sort)"
  [[ -n "$a" ]] || die "$name has no LC_UUID, so nothing identifies it"
  [[ "$a" == "$b" ]] || die "$name in the bundle is not the vendored build"
  echo "    $name"
done

for embedded in "$EMBEDDED_DIR"/*.dylib; do
  name="$(basename "$embedded")"
  [[ -f "$FFMPEG_LIB/$name" ]] ||
    die "$name is in the bundle and was never vendored, so nothing describes it"
done

# ---- sign ------------------------------------------------------------------
#
# Inside out, deepest first. A framework's seal covers its contents, so signing
# one before the dylibs inside it produces a bundle that verifies here and is
# refused on the first machine that has never seen it.
step "signing"
if [[ $ADHOC -eq 1 ]]; then
  # No hardened runtime, and this is the one place the ad-hoc build differs
  # from the real one. The hardened runtime turns on library validation, which
  # requires every framework a process maps to carry the *same Team ID* as the
  # process — and an ad-hoc signature has no team at all, so the app refuses to
  # load its own engine with "different Team IDs" before it draws a window. A
  # Developer ID gives everything here one team and the problem does not exist.
  # The alternative would be to ship
  # com.apple.security.cs.disable-library-validation, which is turning off the
  # thing the hardened runtime is for in order to make a test build launch.
  SIGN_ARGS=(--sign - --timestamp=none)
  echo "    ad hoc, without the hardened runtime — this is a build to look at"
else
  SIGN_ARGS=(--sign "$IDENTITY" --options runtime --timestamp)
fi

# Nested code gets no entitlements: the sandbox belongs to the app, and a
# framework carrying its own copy is how "the app is not sandboxed after all"
# happens.
while IFS= read -r -d '' target; do
  codesign --force "${SIGN_ARGS[@]}" "$target"
done < <(find "$APP/Contents" -depth \( -name '*.dylib' -o -name '*.so' \) -print0)

while IFS= read -r -d '' framework; do
  versioned="$framework/Versions/A"
  codesign --force "${SIGN_ARGS[@]}" \
    "$([[ -d "$versioned" ]] && echo "$versioned" || echo "$framework")"
done < <(find "$APP/Contents" -depth -name '*.framework' -print0)

codesign --force "${SIGN_ARGS[@]}" \
  --entitlements "$APP_DIR/macos/Runner/Release.entitlements" \
  "$APP"

step "verifying the signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign --display --entitlements - "$APP" 2>/dev/null |
  grep -q 'com.apple.security.app-sandbox' ||
  die "the signed app is not sandboxed"

# Nothing outside the bundle and the system: a dylib resolved from /opt or
# /usr/local works on the machine that built it and nowhere else.
step "checking nothing is linked from outside the bundle"
STRAY=""
while IFS= read -r -d '' binary; do
  file "$binary" | grep -q 'Mach-O' || continue
  while read -r dep; do
    case "$dep" in
      /usr/lib/*|/System/*|@rpath/*|@loader_path/*|@executable_path/*) ;;
      "") ;;
      *) STRAY="$STRAY
  $(basename "$binary") -> $dep" ;;
    esac
    # Only the tab-indented lines are dependencies. A universal binary makes
    # otool print a header per slice, so anything else here is a file name.
  done < <(otool -L "$binary" 2>/dev/null | grep '^	' | awk '{print $1}')
done < <(find "$APP/Contents" -type f -perm +111 -print0)
[[ -z "$STRAY" ]] || die "linked from outside the bundle, so it will not be
  there on any other Mac:$STRAY"

# ---- disk image ------------------------------------------------------------
#
# Built twice when notarizing, which is not waste: the ticket for the app is
# fetched by the hash of the app, and stapling it changes the app — so the DMG
# has to be made again around the stapled copy and then notarized on its own
# account. Two submissions, and what they buy is an app in /Applications that
# verifies with no network, long after the disk image it arrived in was thrown
# away.
mkdir -p "$OUT"
STAGE="$OUT/.stage"
DMG="$OUT/vdodtor-$VERSION.dmg"

build_dmg() {
  rm -rf "$STAGE"
  mkdir -p "$STAGE/Licences"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"

  # The same two documents the About sheet shows, beside the app as well as
  # inside it: somebody deciding whether to install should not have to install
  # first. LGPL 2.1 §6 wants the licence to accompany the distribution, and
  # the disk image is the distribution.
  cp "$APP_DIR/assets/notices/THIRD_PARTY_NOTICES.md" "$STAGE/Licences/"
  cp "$APP_DIR/assets/notices/LGPL-2.1.txt" "$STAGE/Licences/"
  cp "$APP_DIR"/assets/fonts/OFL-*.txt "$STAGE/Licences/"

  rm -f "$DMG"
  hdiutil create -quiet -volname "vdodtor $VERSION" -srcfolder "$STAGE" \
    -ov -format UDZO "$DMG"
  rm -rf "$STAGE"
  [[ $ADHOC -eq 1 ]] || codesign --force --sign "$IDENTITY" --timestamp "$DMG"
}

if [[ $NOTARIZE -eq 1 ]]; then
  step "notarizing the app (this waits on Apple, and can take a few minutes)"
  ZIP="$OUT/vdodtor-$VERSION.zip"
  rm -f "$ZIP"
  # ditto rather than zip: the latter does not preserve symlinks or resource
  # forks, and an app that survives the round trip is the point.
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
  rm -f "$ZIP"
  xcrun stapler staple "$APP"
fi

step "building the disk image"
build_dmg

if [[ $NOTARIZE -eq 1 ]]; then
  step "notarizing the disk image"
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$DMG"

  step "checking Gatekeeper would let a stranger open it"
  xcrun stapler validate "$DMG"
  xcrun stapler validate "$APP"
  spctl --assess --type open --context context:primary-signature -vv "$DMG"
  spctl --assess --type execute -vv "$APP"
fi

step "done"
echo "    $DMG"
ls -lh "$DMG" | awk '{print "    " $5}'
if [[ $NOTARIZE -eq 0 ]]; then
  echo
  echo "    NOT notarized. Gatekeeper will refuse this on any Mac but this one."
fi
if [[ $ADHOC -eq 1 ]]; then
  echo "    NOT hardened. A shipping build is signed with a Developer ID and"
  echo "    --options runtime; see the signing step for why this one is not."
fi
