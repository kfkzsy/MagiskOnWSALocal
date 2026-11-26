// AMArchiveCore — a small, UI-free wrapper around libarchive.
// Plain C so it can be unit-tested on any host (see tests/test_core.c).
#ifndef AM_ARCHIVE_CORE_H
#define AM_ARCHIVE_CORE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    AM_OK = 0,
    AM_ERR = -1,
    AM_CANCELLED = -2,
    AM_NEED_PASSWORD = -3,
    AM_BAD_PASSWORD = -4,
    AM_UNSUPPORTED = -5,
};

typedef enum {
    AM_FMT_ZIP = 0,
    AM_FMT_7Z,
    AM_FMT_TAR,
    AM_FMT_TAR_GZ,
    AM_FMT_TAR_BZ2,
    AM_FMT_TAR_XZ,
    AM_FMT_TAR_ZST,
    AM_FMT_TAR_LZ4,
    AM_FMT_ISO,
    AM_FMT_CPIO,
    // Single-file compressors (exactly one regular file as input)
    AM_FMT_GZ,
    AM_FMT_BZ2,
    AM_FMT_XZ,
    AM_FMT_ZST,
    AM_FMT_LZ4,
    /* RAR5 container, "store" method: RAR's compression algorithm is proprietary to RARLAB, but the
     * format itself is documented, so files are packed without compression (readable by all RAR tools). */
    AM_FMT_RAR,
    AM_FMT_COUNT
} am_format;

typedef enum {
    AM_ENC_NONE = 0,
    AM_ENC_ZIPCRYPTO,
    AM_ENC_AES256,
} am_encryption;

/* Return non-zero to cancel. `done`/`total` are bytes; `name` may be NULL. */
typedef int (*am_progress_cb)(void *ctx, int64_t done, int64_t total, const char *name);

typedef struct {
    const char *password;            /* NULL if none */
    const char *const *passwords;    /* extra candidates, tried in order (e.g. a saved password list) */
    int password_count;
    const char *charset;    /* NULL/"" = auto (UTF-8, falling back to GBK), or e.g. "CP936", "BIG5", "SHIFT_JIS" */
    /* Optional entry filter: return non-zero to extract the entry with this (sanitised, UTF-8) path. */
    int (*include)(void *ctx, const char *path);
    void *include_ctx;
} am_read_opts;

typedef struct {
    am_format format;
    int level;              /* 0 (store) .. 9 (best) */
    const char *password;   /* ZIP only */
    am_encryption encryption;
    const char *prefix;     /* optional folder all entries are stored under, e.g. "Photos" */
} am_write_opts;

typedef struct {
    const char *path;       /* UTF-8 */
    int64_t size;
    int is_dir;
    int is_encrypted;
} am_entry_info;

/* Called once per entry while listing. Return non-zero to stop. */
typedef int (*am_entry_cb)(void *ctx, const am_entry_info *info);

/* Extract `archive` into existing directory `dest_dir`. */
int am_extract(const char *archive, const char *dest_dir, const am_read_opts *opts,
               am_progress_cb cb, void *ctx, char *err, size_t errlen);

/* Same, for an archive split into `count` volumes given in order (e.g. x.part1.rar, x.part2.rar
 * or x.7z.001, x.7z.002); the volumes are read as one continuous stream. */
int am_extract_volumes(const char *const *volumes, int count, const char *dest_dir, const am_read_opts *opts,
                       am_progress_cb cb, void *ctx, char *err, size_t errlen);

/* List entries without extracting. */
int am_list(const char *archive, const am_read_opts *opts, am_entry_cb cb, void *ctx,
            char *err, size_t errlen);
int am_list_volumes(const char *const *volumes, int count, const am_read_opts *opts, am_entry_cb cb,
                    void *ctx, char *err, size_t errlen);

/* Create `output` from `count` input paths (files or directories). Each input is stored
 * under its own last path component, recursing into directories. */
int am_create(const char *output, const char *const *inputs, int count, const am_write_opts *opts,
              am_progress_cb cb, void *ctx, char *err, size_t errlen);

/* Splits `path` into `parts` consecutive pieces written to `outputs[0..parts-1]` (like 7-Zip's
 * ".001/.002" volumes; concatenating them restores the file). Works from the end, truncating the
 * source as it goes, so it needs little extra space. `path` no longer exists on success. */
int am_split_file(const char *path, int parts, const char *const *outputs, am_progress_cb cb, void *ctx,
                  char *err, size_t errlen);

/* File extension (without dot) for a format, e.g. "tar.gz". */
const char *am_format_extension(am_format fmt);
/* 1 if `fmt` only accepts a single regular file. */
int am_format_is_single_file(am_format fmt);
/* 1 if `fmt` supports a password. */
int am_format_supports_password(am_format fmt);

/* Call once at start-up: makes libarchive treat names as UTF-8. */
void am_init(void);

#ifdef __cplusplus
}
#endif
#endif
