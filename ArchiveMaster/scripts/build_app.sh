#!/usr/bin/env bash
# Builds ArchiveMaster.ipa (unsigned apart from an ad-hoc linker signature) on Linux.
# Run scripts/build_deps.sh first. Output: dist/ArchiveMaster.ipa
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$ROOT/.build}"
SDK="${SDK:-$WORK/iPhoneOS16.5.sdk}"
DEPS="${DEPS:-$WORK/deps}"
MIN_IOS=15.0
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
  -framework UniformTypeIdentifiers -framework ImageIO \
  -Wl,-dead_strip -Wl,-adhoc_codesign -o "$BIN"
llvm-strip -x "$BIN" 2>/dev/null || true

# Bundle resources: binary Info.plist, PkgInfo, icons, localized display names.
python3 -I - "$ROOT/Resources/Info.plist" "$STAGE/Payload/$APP.app" <<'PY'
import os, plistlib, sys
src, app = sys.argv[1], sys.argv[2]
with open(src, "rb") as f:
    info = plistlib.load(f)
with open(os.path.join(app, "Info.plist"), "wb") as f:
    plistlib.dump(info, f, fmt=plistlib.FMT_BINARY)
with open(os.path.join(app, "PkgInfo"), "w") as f:
    f.write("APPL????")
for lang, name in (("zh-Hans", "解压大师"), ("en", "Unarchiver")):
    os.makedirs(os.path.join(app, lang + ".lproj"), exist_ok=True)
    with open(os.path.join(app, lang + ".lproj", "InfoPlist.strings"), "wb") as f:
        plistlib.dump({"CFBundleDisplayName": name, "CFBundleName": name}, f, fmt=plistlib.FMT_BINARY)
PY
python3 -I "$ROOT/scripts/make_icon.py" "$WORK/icons"
cp "$WORK"/icons/AppIcon*x*.png "$STAGE/Payload/$APP.app/"
cp "$WORK/icons/AppIcon1024.png" "$STAGE/iTunesArtwork"

rm -f "$DIST/$APP.ipa"
( cd "$STAGE" && zip -qry -X "$DIST/$APP.ipa" Payload iTunesArtwork )
echo "built $DIST/$APP.ipa ($(du -h "$DIST/$APP.ipa" | cut -f1))"
