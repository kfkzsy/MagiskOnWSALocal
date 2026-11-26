#!/usr/bin/env bash
# Cross-compiles libarchive (+ zstd, lz4, liblzma) as static libraries for iOS arm64
# on Linux, using clang + lld and the iOS SDK published by the Theos project.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$ROOT/.build}"
DL="$WORK/downloads"; SRC="$WORK/src"; PREFIX="$WORK/deps"
MIN_IOS="${MIN_IOS:-14.0}"
SDK_VER="16.5"
LIBARCHIVE_VER="3.8.1"; ZSTD_VER="1.5.7"; LZ4_VER="1.10.0"; XZ_VER="5.8.1"
JOBS="$(nproc)"
mkdir -p "$DL" "$SRC" "$PREFIX/include" "$PREFIX/lib"

fetch() { [ -s "$DL/$2" ] || curl -fL --retry 3 -o "$DL/$2" "$1"; }
fetch "https://github.com/theos/sdks/releases/latest/download/iPhoneOS${SDK_VER}.sdk.tar.xz" sdk.tar.xz
fetch "https://github.com/libarchive/libarchive/releases/download/v${LIBARCHIVE_VER}/libarchive-${LIBARCHIVE_VER}.tar.xz" libarchive.tar.xz
fetch "https://github.com/facebook/zstd/releases/download/v${ZSTD_VER}/zstd-${ZSTD_VER}.tar.gz" zstd.tar.gz
fetch "https://github.com/lz4/lz4/releases/download/v${LZ4_VER}/lz4-${LZ4_VER}.tar.gz" lz4.tar.gz
fetch "https://github.com/tukaani-project/xz/releases/download/v${XZ_VER}/xz-${XZ_VER}.tar.xz" xz.tar.xz

SDK="$WORK/iPhoneOS${SDK_VER}.sdk"
[ -d "$SDK" ] || tar -C "$WORK" -xf "$DL/sdk.tar.xz"
for f in libarchive zstd lz4 xz; do
  ls -d "$SRC/$f"-* >/dev/null 2>&1 || tar -C "$SRC" -xf "$DL/$f".tar.*
done

LLVM_BIN="$(dirname "$(readlink -f "$(command -v clang)")")"
export PATH="$LLVM_BIN:$PATH"
export CC="clang -target arm64-apple-ios${MIN_IOS} -isysroot $SDK"
export CFLAGS="-O2 -I$PREFIX/include"
export LDFLAGS="-fuse-ld=lld -L$PREFIX/lib"
export AR=llvm-ar RANLIB=llvm-ranlib NM=llvm-nm STRIP=llvm-strip
HOST=aarch64-apple-darwin

# zstd
if [ ! -f "$PREFIX/lib/libzstd.a" ]; then
  make -C "$SRC/zstd-$ZSTD_VER/lib" -j"$JOBS" libzstd.a-mt CC="$CC" AR="$AR" CFLAGS="$CFLAGS" >/dev/null
  cp "$SRC/zstd-$ZSTD_VER/lib/libzstd.a" "$PREFIX/lib/"
  cp "$SRC/zstd-$ZSTD_VER/lib/"{zstd.h,zstd_errors.h,zdict.h} "$PREFIX/include/"
fi

# lz4
if [ ! -f "$PREFIX/lib/liblz4.a" ]; then
  make -C "$SRC/lz4-$LZ4_VER/lib" -j"$JOBS" liblz4.a CC="$CC" AR="$AR" CFLAGS="$CFLAGS" >/dev/null
  cp "$SRC/lz4-$LZ4_VER/lib/liblz4.a" "$PREFIX/lib/"
  cp "$SRC/lz4-$LZ4_VER/lib/"{lz4.h,lz4hc.h,lz4frame.h} "$PREFIX/include/"
fi

# liblzma (xz)
if [ ! -f "$PREFIX/lib/liblzma.a" ]; then
  ( cd "$SRC/xz-$XZ_VER" && ./configure --host=$HOST --prefix="$PREFIX" --enable-static --disable-shared \
      --disable-xz --disable-xzdec --disable-lzmadec --disable-lzmainfo --disable-scripts --disable-doc \
      --disable-nls --disable-rpath >"$WORK/xz-configure.log" && make -j"$JOBS" >/dev/null && make install >/dev/null )
fi

# libarchive. Its AES/HMAC code picks CommonCrypto only when macOS macros are set;
# CommonCrypto is on iOS too, so enable it there (needed for encrypted ZIP read/write).
LA="$SRC/libarchive-$LIBARCHIVE_VER"
sed -i -E "s/# if MAC_OS_X_VERSION_MAX_ALLOWED >= 10[0-9]+/# if 1/" \
  "$LA/libarchive/archive_cryptor_private.h" "$LA/libarchive/archive_hmac_private.h"
if [ ! -f "$PREFIX/lib/libarchive.a" ]; then
  ( cd "$LA" && CPPFLAGS="-I$PREFIX/include -I$SDK/usr/include/libxml2" ./configure --host=$HOST --prefix="$PREFIX" \
      --enable-static --disable-shared --disable-bsdtar --disable-bsdcpio --disable-bsdcat --disable-bsdunzip \
      --without-openssl --without-nettle --without-mbedtls --with-xml2 --without-expat \
      --with-zlib --with-bz2lib --with-lzma --with-zstd --with-lz4 --with-iconv --disable-acl --disable-xattr \
      >"$WORK/libarchive-configure.log" && make -j"$JOBS" >/dev/null && make install >/dev/null )
fi
echo "deps ready in $PREFIX"
