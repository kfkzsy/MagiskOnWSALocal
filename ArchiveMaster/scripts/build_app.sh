#!/usr/bin/env bash
# Builds ArchiveMaster.ipa (unsigned apart from an ad-hoc linker signature) on Linux.
# Run scripts/build_deps.sh first. Output: dist/ArchiveMaster.ipa
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$ROOT/.build}"
SDK="${SDK:-$WORK/iPhoneOS16.5.sdk}"
DEPS="${DEPS:-$WORK/deps}"
MIN_IOS=15.0
# The linked-SDK version recorded in the binary. iPhone Duo only lets apps linked against the
# iOS 27.1 SDK fill its inner display (older ones are letterboxed), and iOS 26+ applies the
# Liquid Glass design to apps linked against SDK 26 or later.
LINK_SDK="${LINK_SDK:-27.1}"
APP=ArchiveMaster
OBJ="$WORK/obj"; STAGE="$WORK/stage"; DIST="$ROOT/dist"
LLVM_BIN="$(dirname "$(readlink -f "$(command -v clang)")")"
export PATH="$LLVM_BIN:$PATH"

[ -d "$SDK" ] && [ -f "$DEPS/lib/libarchive.a" ] || { echo "run scripts/build_deps.sh first" >&2; exit 1; }
rm -rf "$OBJ" "$STAGE"; mkdir -p "$OBJ" "$STAGE/Payload/$APP.app" "$DIST"

CFLAGS=(-target "arm64-apple-ios$MIN_IOS" -isysroot "$SDK" -I"$DEPS/include" -I"$ROOT/Sources"
        -O2 -g0 -Wall -Wextra -Wno-unused-parameter -Wunguarded-availability-new -Werror=unguarded-availability-new)
for src in "$ROOT"/Sources/*.m "$ROOT"/Sources/*.c; do
  extra=()
  [[ "$src" == *.m ]] && extra=(-fobjc-arc -fmodules -fno-autolink)
  clang "${CFLAGS[@]}" "${extra[@]}" -c "$src" -o "$OBJ/$(basename "$src").o"
done

BIN="$STAGE/Payload/$APP.app/$APP"
clang -target "arm64-apple-ios$MIN_IOS" -isysroot "$SDK" -fuse-ld=lld -fobjc-arc -fobjc-link-runtime \
  "$OBJ"/*.o "$DEPS/lib/libarchive.a" "$DEPS/lib/libzstd.a" "$DEPS/lib/liblz4.a" "$DEPS/lib/liblzma.a" \
  -lz -lbz2 -liconv -lxml2 \
  -framework UIKit -framework Foundation -framework CoreFoundation -framework CoreGraphics -framework QuartzCore \
  -framework QuickLook -framework QuickLookThumbnailing -framework Photos -framework PhotosUI \
  -framework UniformTypeIdentifiers -framework ImageIO -framework AVFoundation -framework CoreMedia \
  -framework CoreLocation -framework Security \
  -Wl,-platform_version,ios,"$MIN_IOS","$LINK_SDK" -Wl,-dead_strip -Wl,-adhoc_codesign -o "$BIN"
# Local symbols are kept on purpose: the in-app crash report then shows function names.

# Bundle resources: binary Info.plist, PkgInfo, icons, localizations (zh-Hans is the development language).
python3 -I "$ROOT/scripts/l10n_check.py" check "$ROOT/Resources/en.lproj/Localizable.strings" "$ROOT"/Sources/*.m
APPDIR="$STAGE/Payload/$APP.app"
python3 -I - "$ROOT/Resources/Info.plist" "$APPDIR" <<'PY'
import os, plistlib, sys
src, app = sys.argv[1], sys.argv[2]
with open(src, "rb") as f:
    info = plistlib.load(f)
with open(os.path.join(app, "Info.plist"), "wb") as f:
    plistlib.dump(info, f, fmt=plistlib.FMT_BINARY)
with open(os.path.join(app, "PkgInfo"), "w") as f:
    f.write("APPL????")
PY
for lproj in "$ROOT"/Resources/*.lproj; do
  mkdir -p "$APPDIR/$(basename "$lproj")"
  for strings in "$lproj"/*.strings; do
    python3 -I "$ROOT/scripts/l10n_check.py" compile "$strings" "$APPDIR/$(basename "$lproj")/$(basename "$strings")"
  done
done
python3 -I "$ROOT/scripts/make_icon.py" "$WORK/icons"
cp "$WORK"/icons/AppIcon*x*.png "$STAGE/Payload/$APP.app/"
cp "$WORK/icons/AppIcon1024.png" "$STAGE/iTunesArtwork"

rm -f "$DIST/$APP.ipa"
( cd "$STAGE" && zip -qry -X "$DIST/$APP.ipa" Payload iTunesArtwork )
echo "built $DIST/$APP.ipa ($(du -h "$DIST/$APP.ipa" | cut -f1))"
