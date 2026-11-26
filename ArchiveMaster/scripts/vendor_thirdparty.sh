#!/usr/bin/env bash
# Copies the third-party sources the app needs (libarchive, zstd, lz4, liblzma) into ThirdParty/,
# with the iOS config.h headers from Xcode/ThirdPartyConfig, so Xcode can compile everything
# natively (device and simulator) without autotools. Run once before `xcodegen`.
# The file lists are exactly what the working iOS build compiled.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DL="${DL:-$ROOT/.build/downloads}"
OUT="$ROOT/ThirdParty"
SRC="$(mktemp -d)"
trap 'rm -rf "$SRC"' EXIT
LIBARCHIVE_VER=3.8.1; ZSTD_VER=1.5.7; LZ4_VER=1.10.0; XZ_VER=5.8.1
mkdir -p "$DL"
fetch() { [ -s "$DL/$2" ] || curl -fL --retry 3 -o "$DL/$2" "$1"; }
fetch "https://github.com/libarchive/libarchive/releases/download/v$LIBARCHIVE_VER/libarchive-$LIBARCHIVE_VER.tar.xz" libarchive.tar.xz
fetch "https://github.com/facebook/zstd/releases/download/v$ZSTD_VER/zstd-$ZSTD_VER.tar.gz" zstd.tar.gz
fetch "https://github.com/lz4/lz4/releases/download/v$LZ4_VER/lz4-$LZ4_VER.tar.gz" lz4.tar.gz
fetch "https://github.com/tukaani-project/xz/releases/download/v$XZ_VER/xz-$XZ_VER.tar.xz" xz.tar.xz
for f in libarchive.tar.xz zstd.tar.gz lz4.tar.gz xz.tar.xz; do tar -C "$SRC" -xf "$DL/$f"; done

copy() {  # copy <from-root> <to-root> <relative paths...>
  local from="$1" to="$2"; shift 2
  for rel in "$@"; do mkdir -p "$to/$(dirname "$rel")"; cp "$from/$rel" "$to/$rel"; done
}
headers() {  # all headers under <from-root>/<dir> -> <to-root>/<dir>
  local from="$1" to="$2" dir="$3"
  (cd "$from" && find "$dir" -name '*.h') | while read -r rel; do mkdir -p "$to/$(dirname "$rel")"; cp "$from/$rel" "$to/$rel"; done
}

rm -rf "$OUT"; mkdir -p "$OUT"

# libarchive (+ iOS config.h; AES/HMAC use CommonCrypto on iOS too)
LA="$SRC/libarchive-$LIBARCHIVE_VER"
sed -i.bak -E "s/# if MAC_OS_X_VERSION_MAX_ALLOWED >= 10[0-9]+/# if 1/" "$LA/libarchive/archive_cryptor_private.h" "$LA/libarchive/archive_hmac_private.h"
copy "$LA" "$OUT/libarchive" \
  libarchive/archive_acl.c \
  libarchive/archive_check_magic.c \
  libarchive/archive_cmdline.c \
  libarchive/archive_cryptor.c \
  libarchive/archive_digest.c \
  libarchive/archive_entry.c \
  libarchive/archive_entry_copy_stat.c \
  libarchive/archive_entry_link_resolver.c \
  libarchive/archive_entry_sparse.c \
  libarchive/archive_entry_stat.c \
  libarchive/archive_entry_strmode.c \
  libarchive/archive_entry_xattr.c \
  libarchive/archive_hmac.c \
  libarchive/archive_match.c \
  libarchive/archive_options.c \
  libarchive/archive_pack_dev.c \
  libarchive/archive_parse_date.c \
  libarchive/archive_pathmatch.c \
  libarchive/archive_ppmd7.c \
  libarchive/archive_ppmd8.c \
  libarchive/archive_random.c \
  libarchive/archive_rb.c \
  libarchive/archive_read.c \
  libarchive/archive_read_add_passphrase.c \
  libarchive/archive_read_append_filter.c \
  libarchive/archive_read_data_into_fd.c \
  libarchive/archive_read_disk_entry_from_file.c \
  libarchive/archive_read_disk_posix.c \
  libarchive/archive_read_disk_set_standard_lookup.c \
  libarchive/archive_read_extract.c \
  libarchive/archive_read_extract2.c \
  libarchive/archive_read_open_fd.c \
  libarchive/archive_read_open_file.c \
  libarchive/archive_read_open_filename.c \
  libarchive/archive_read_open_memory.c \
  libarchive/archive_read_set_format.c \
  libarchive/archive_read_set_options.c \
  libarchive/archive_read_support_filter_all.c \
  libarchive/archive_read_support_filter_bzip2.c \
  libarchive/archive_read_support_filter_by_code.c \
  libarchive/archive_read_support_filter_compress.c \
  libarchive/archive_read_support_filter_grzip.c \
  libarchive/archive_read_support_filter_gzip.c \
  libarchive/archive_read_support_filter_lrzip.c \
  libarchive/archive_read_support_filter_lz4.c \
  libarchive/archive_read_support_filter_lzop.c \
  libarchive/archive_read_support_filter_none.c \
  libarchive/archive_read_support_filter_program.c \
  libarchive/archive_read_support_filter_rpm.c \
  libarchive/archive_read_support_filter_uu.c \
  libarchive/archive_read_support_filter_xz.c \
  libarchive/archive_read_support_filter_zstd.c \
  libarchive/archive_read_support_format_7zip.c \
  libarchive/archive_read_support_format_all.c \
  libarchive/archive_read_support_format_ar.c \
  libarchive/archive_read_support_format_by_code.c \
  libarchive/archive_read_support_format_cab.c \
  libarchive/archive_read_support_format_cpio.c \
  libarchive/archive_read_support_format_empty.c \
  libarchive/archive_read_support_format_iso9660.c \
  libarchive/archive_read_support_format_lha.c \
  libarchive/archive_read_support_format_mtree.c \
  libarchive/archive_read_support_format_rar.c \
  libarchive/archive_read_support_format_rar5.c \
  libarchive/archive_read_support_format_raw.c \
  libarchive/archive_read_support_format_tar.c \
  libarchive/archive_read_support_format_warc.c \
  libarchive/archive_read_support_format_xar.c \
  libarchive/archive_read_support_format_zip.c \
  libarchive/archive_string.c \
  libarchive/archive_string_sprintf.c \
  libarchive/archive_time.c \
  libarchive/archive_util.c \
  libarchive/archive_version_details.c \
  libarchive/archive_virtual.c \
  libarchive/archive_write.c \
  libarchive/archive_write_disk_posix.c \
  libarchive/archive_write_disk_set_standard_lookup.c \
  libarchive/archive_write_open_fd.c \
  libarchive/archive_write_open_file.c \
  libarchive/archive_write_open_filename.c \
  libarchive/archive_write_open_memory.c \
  libarchive/archive_write_add_filter.c \
  libarchive/archive_write_add_filter_b64encode.c \
  libarchive/archive_write_add_filter_by_name.c \
  libarchive/archive_write_add_filter_bzip2.c \
  libarchive/archive_write_add_filter_compress.c \
  libarchive/archive_write_add_filter_grzip.c \
  libarchive/archive_write_add_filter_gzip.c \
  libarchive/archive_write_add_filter_lrzip.c \
  libarchive/archive_write_add_filter_lz4.c \
  libarchive/archive_write_add_filter_lzop.c \
  libarchive/archive_write_add_filter_none.c \
  libarchive/archive_write_add_filter_program.c \
  libarchive/archive_write_add_filter_uuencode.c \
  libarchive/archive_write_add_filter_xz.c \
  libarchive/archive_write_add_filter_zstd.c \
  libarchive/archive_write_set_format.c \
  libarchive/archive_write_set_format_7zip.c \
  libarchive/archive_write_set_format_ar.c \
  libarchive/archive_write_set_format_by_name.c \
  libarchive/archive_write_set_format_cpio.c \
  libarchive/archive_write_set_format_cpio_binary.c \
  libarchive/archive_write_set_format_cpio_newc.c \
  libarchive/archive_write_set_format_cpio_odc.c \
  libarchive/archive_write_set_format_filter_by_ext.c \
  libarchive/archive_write_set_format_iso9660.c \
  libarchive/archive_write_set_format_mtree.c \
  libarchive/archive_write_set_format_pax.c \
  libarchive/archive_write_set_format_raw.c \
  libarchive/archive_write_set_format_shar.c \
  libarchive/archive_write_set_format_ustar.c \
  libarchive/archive_write_set_format_v7tar.c \
  libarchive/archive_write_set_format_gnutar.c \
  libarchive/archive_write_set_format_warc.c \
  libarchive/archive_write_set_format_xar.c \
  libarchive/archive_write_set_format_zip.c \
  libarchive/archive_write_set_options.c \
  libarchive/archive_write_set_passphrase.c \
  libarchive/filter_fork_posix.c \
  libarchive/xxhash.c \
  libarchive/archive_blake2s_ref.c \
  libarchive/archive_blake2sp_ref.c
headers "$LA" "$OUT/libarchive" libarchive
cp "$ROOT/Xcode/ThirdPartyConfig/libarchive/config.h" "$OUT/libarchive/libarchive/config.h"

# liblzma (xz)
XZ="$SRC/xz-$XZ_VER/src"
copy "$XZ" "$OUT/xz" \
  common/tuklib_physmem.c \
  common/tuklib_cpucores.c \
  liblzma/common/common.c \
  liblzma/common/block_util.c \
  liblzma/common/easy_preset.c \
  liblzma/common/filter_common.c \
  liblzma/common/hardware_physmem.c \
  liblzma/common/index.c \
  liblzma/common/stream_flags_common.c \
  liblzma/common/string_conversion.c \
  liblzma/common/vli_size.c \
  liblzma/common/hardware_cputhreads.c \
  liblzma/common/outqueue.c \
  liblzma/common/alone_encoder.c \
  liblzma/common/block_buffer_encoder.c \
  liblzma/common/block_encoder.c \
  liblzma/common/block_header_encoder.c \
  liblzma/common/easy_buffer_encoder.c \
  liblzma/common/easy_encoder.c \
  liblzma/common/easy_encoder_memusage.c \
  liblzma/common/filter_buffer_encoder.c \
  liblzma/common/filter_encoder.c \
  liblzma/common/filter_flags_encoder.c \
  liblzma/common/index_encoder.c \
  liblzma/common/stream_buffer_encoder.c \
  liblzma/common/stream_encoder.c \
  liblzma/common/stream_flags_encoder.c \
  liblzma/common/vli_encoder.c \
  liblzma/common/stream_encoder_mt.c \
  liblzma/common/microlzma_encoder.c \
  liblzma/common/alone_decoder.c \
  liblzma/common/auto_decoder.c \
  liblzma/common/block_buffer_decoder.c \
  liblzma/common/block_decoder.c \
  liblzma/common/block_header_decoder.c \
  liblzma/common/easy_decoder_memusage.c \
  liblzma/common/file_info.c \
  liblzma/common/filter_buffer_decoder.c \
  liblzma/common/filter_decoder.c \
  liblzma/common/filter_flags_decoder.c \
  liblzma/common/index_decoder.c \
  liblzma/common/index_hash.c \
  liblzma/common/stream_buffer_decoder.c \
  liblzma/common/stream_decoder.c \
  liblzma/common/stream_flags_decoder.c \
  liblzma/common/vli_decoder.c \
  liblzma/common/stream_decoder_mt.c \
  liblzma/common/microlzma_decoder.c \
  liblzma/common/lzip_decoder.c \
  liblzma/check/check.c \
  liblzma/check/crc32_fast.c \
  liblzma/check/crc64_fast.c \
  liblzma/check/sha256.c \
  liblzma/lz/lz_encoder.c \
  liblzma/lz/lz_encoder_mf.c \
  liblzma/lz/lz_decoder.c \
  liblzma/lzma/lzma_encoder_presets.c \
  liblzma/lzma/lzma_encoder.c \
  liblzma/lzma/lzma_encoder_optimum_fast.c \
  liblzma/lzma/lzma_encoder_optimum_normal.c \
  liblzma/lzma/fastpos_table.c \
  liblzma/lzma/lzma_decoder.c \
  liblzma/lzma/lzma2_encoder.c \
  liblzma/lzma/lzma2_decoder.c \
  liblzma/rangecoder/price_table.c \
  liblzma/delta/delta_common.c \
  liblzma/delta/delta_encoder.c \
  liblzma/delta/delta_decoder.c \
  liblzma/simple/simple_coder.c \
  liblzma/simple/simple_encoder.c \
  liblzma/simple/simple_decoder.c \
  liblzma/simple/x86.c \
  liblzma/simple/powerpc.c \
  liblzma/simple/ia64.c \
  liblzma/simple/arm.c \
  liblzma/simple/armthumb.c \
  liblzma/simple/arm64.c \
  liblzma/simple/sparc.c \
  liblzma/simple/riscv.c
headers "$XZ" "$OUT/xz" liblzma
headers "$XZ" "$OUT/xz" common
cp "$ROOT/Xcode/ThirdPartyConfig/xz/config.h" "$OUT/xz/config.h"

# zstd (multithreaded, legacy formats v0.5+; the x86-64 assembly decoder is left out)
ZS="$SRC/zstd-$ZSTD_VER/lib"
copy "$ZS" "$OUT/zstd" \
  common/debug.c \
  common/entropy_common.c \
  common/error_private.c \
  common/fse_decompress.c \
  common/pool.c \
  common/threading.c \
  common/xxhash.c \
  common/zstd_common.c \
  legacy/zstd_v05.c \
  legacy/zstd_v06.c \
  legacy/zstd_v07.c \
  compress/fse_compress.c \
  compress/hist.c \
  compress/huf_compress.c \
  compress/zstd_compress.c \
  compress/zstd_compress_literals.c \
  compress/zstd_compress_sequences.c \
  compress/zstd_compress_superblock.c \
  compress/zstd_double_fast.c \
  compress/zstd_fast.c \
  compress/zstd_lazy.c \
  compress/zstd_ldm.c \
  compress/zstd_opt.c \
  compress/zstd_preSplit.c \
  compress/zstdmt_compress.c \
  decompress/huf_decompress.c \
  decompress/zstd_ddict.c \
  decompress/zstd_decompress.c \
  decompress/zstd_decompress_block.c \
  dictBuilder/cover.c \
  dictBuilder/divsufsort.c \
  dictBuilder/fastcover.c \
  dictBuilder/zdict.c
headers "$ZS" "$OUT/zstd" .
cp "$ZS/zstd.h" "$ZS/zstd_errors.h" "$ZS/zdict.h" "$OUT/zstd/"

# lz4
L4="$SRC/lz4-$LZ4_VER/lib"
copy "$L4" "$OUT/lz4" \
  lz4.c \
  lz4file.c \
  lz4frame.c \
  lz4hc.c \
  xxhash.c
headers "$L4" "$OUT/lz4" .

# License texts travel with the code.
cp "$LA/COPYING" "$OUT/libarchive/COPYING"
cp "$SRC/xz-$XZ_VER/COPYING" "$OUT/xz/COPYING"
cp "$SRC/zstd-$ZSTD_VER/LICENSE" "$OUT/zstd/LICENSE"
cp "$L4/LICENSE" "$OUT/lz4/LICENSE"
echo "ThirdParty/ ready: $(find "$OUT" -name '*.c' | wc -l | tr -d ' ') C files"
