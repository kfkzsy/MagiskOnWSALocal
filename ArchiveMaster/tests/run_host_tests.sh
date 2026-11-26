#!/usr/bin/env bash
# Builds and runs the archive-engine tests on the build host (Linux/macOS).
# Requires a host build of libarchive: LIBARCHIVE_PREFIX=<prefix with include/ and lib/>
# and the libarchive source tree for its test fixtures: LIBARCHIVE_SRC=<libarchive-x.y.z>
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
: "${LIBARCHIVE_PREFIX:?set LIBARCHIVE_PREFIX}" "${LIBARCHIVE_SRC:?set LIBARCHIVE_SRC}"
OUT="${OUT:-$(mktemp -d)}"
mkdir -p "$OUT/samples" "$OUT/work"
python3 -I "$HERE/make_samples.py" "$LIBARCHIVE_SRC/libarchive/test" "$OUT/samples"
cc -O1 -g -Wall -Wextra -I"$LIBARCHIVE_PREFIX/include" -include stdarg.h \
  "$HERE/test_core.c" "$HERE/../Sources/AMArchiveCore.c" \
  "$LIBARCHIVE_PREFIX/lib/libarchive.a" -L"$LIBARCHIVE_PREFIX/lib" \
  -lzstd -llz4 -lcrypto -lbz2 -lz -llzma -o "$OUT/test_core"
"$OUT/test_core" "$OUT/work" "$OUT/samples"
