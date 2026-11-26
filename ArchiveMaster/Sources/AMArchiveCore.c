#include "AMArchiveCore.h"

#include <archive.h>
#include <archive_entry.h>

#include <errno.h>
#include <fcntl.h>
#include <fts.h>
#include <iconv.h>
#include <locale.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define AM_BUF_SIZE (256 * 1024)

/* ------------------------------------------------------------------ helpers */

static void set_err(char *err, size_t len, const char *fmt, ...) {
    if (!err || len == 0) return;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(err, len, fmt, ap);
    va_end(ap);
}

static const char *arc_err(struct archive *a) {
    const char *s = archive_error_string(a);
    return s ? s : "unknown error";
}

void am_init(void) {
    if (!setlocale(LC_CTYPE, "UTF-8") && !setlocale(LC_CTYPE, "en_US.UTF-8"))
        setlocale(LC_CTYPE, "C.UTF-8");
}

static int is_valid_utf8(const unsigned char *s) {
    while (*s) {
        if (*s < 0x80) { s++; continue; }
        int n;
        if ((*s & 0xE0) == 0xC0) { if (*s < 0xC2) return 0; n = 1; }
        else if ((*s & 0xF0) == 0xE0) n = 2;
        else if ((*s & 0xF8) == 0xF0) { if (*s > 0xF4) return 0; n = 3; }
        else return 0;
        s++;
        for (int i = 0; i < n; i++, s++)
            if ((*s & 0xC0) != 0x80) return 0;
    }
    return 1;
}

static char *convert_to_utf8(const char *in, const char *from) {
    iconv_t cd = iconv_open("UTF-8", from);
    if (cd == (iconv_t)-1) return NULL;
    size_t inlen = strlen(in), outcap = inlen * 4 + 4;
    char *out = malloc(outcap);
    if (!out) { iconv_close(cd); return NULL; }
    char *ip = (char *)in, *op = out;
    size_t il = inlen, ol = outcap - 1;
    size_t r = iconv(cd, &ip, &il, &op, &ol);
    iconv_close(cd);
    if (r == (size_t)-1 || il != 0) { free(out); return NULL; }
    *op = '\0';
    return out;
}

/* Returns a malloc'd UTF-8 name for the entry. In auto mode, names that are not valid
 * UTF-8 (typical for ZIPs made on Chinese Windows) are decoded as GB18030 (GBK superset),
 * then Shift_JIS, then BIG5, and finally have stray bytes replaced by '_'. */
static char *entry_name_utf8(struct archive_entry *e, int auto_charset) {
    const char *name = archive_entry_pathname(e);
    if (!name) name = archive_entry_pathname_utf8(e);
    if (!name || !*name) return NULL;
    if (!auto_charset || is_valid_utf8((const unsigned char *)name)) return strdup(name);
    static const char *const fallbacks[] = { "GB18030", "SHIFT_JIS", "BIG5" };
    for (size_t i = 0; i < sizeof fallbacks / sizeof *fallbacks; i++) {
        char *c = convert_to_utf8(name, fallbacks[i]);
        if (c && is_valid_utf8((unsigned char *)c)) return c;
        free(c);
    }
    char *c = strdup(name);
    for (unsigned char *p = (unsigned char *)c; p && *p; p++)
        if (*p >= 0x80) *p = '_';
    return c;
}

/* Normalises an archive path in place: backslashes become '/', and empty, "." and ".."
 * components are dropped so nothing can escape the destination directory.
 * Returns 0 if nothing is left. */
static int sanitize_path(char *p) {
    for (char *q = p; *q; q++) if (*q == '\\') *q = '/';
    char *out = p, *seg = p;
    size_t outlen = 0;
    while (*seg) {
        while (*seg == '/') seg++;
        if (!*seg) break;
        char *end = strchr(seg, '/');
        size_t n = end ? (size_t)(end - seg) : strlen(seg);
        int skip = (n == 1 && seg[0] == '.') || (n == 2 && seg[0] == '.' && seg[1] == '.');
        if (!skip) {
            if (outlen) out[outlen++] = '/';
            memmove(out + outlen, seg, n);
            outlen += n;
        }
        seg += n;
    }
    out[outlen] = '\0';
    return outlen > 0;
}

static int is_junk_path(const char *p) {
    if (strncmp(p, "__MACOSX/", 9) == 0 || strcmp(p, "__MACOSX") == 0) return 1;
    const char *base = strrchr(p, '/');
    base = base ? base + 1 : p;
    return strcmp(base, ".DS_Store") == 0;
}

static char *path_join(const char *a, const char *b) {
    size_t la = strlen(a), lb = strlen(b);
    char *r = malloc(la + lb + 2);
    if (!r) return NULL;
    memcpy(r, a, la);
    size_t o = la;
    if (o && r[o - 1] != '/') r[o++] = '/';
    memcpy(r + o, b, lb + 1);
    return r;
}

static const char *base_name(const char *p) {
    const char *s = strrchr(p, '/');
    return s ? s + 1 : p;
}

/* Name for the payload of a bare compressed file, e.g. "notes.txt.gz" -> "notes.txt". */
static char *raw_output_name(const char *archive) {
    size_t blen = strlen(archive);
    if (blen > 4 && archive[blen - 4] == '.' && archive[blen - 3] >= '0' && archive[blen - 3] <= '9' &&
        archive[blen - 2] >= '0' && archive[blen - 2] <= '9' && archive[blen - 1] >= '0' && archive[blen - 1] <= '9') {
        char *trimmed = strndup(archive, blen - 4); /* "x.gz.001" -> "x.gz" */
        char *r = trimmed ? raw_output_name(trimmed) : NULL;
        free(trimmed);
        return r;
    }
    static const char *const exts[] = { ".gz", ".gzip", ".bz2", ".bz", ".xz", ".lzma", ".zst", ".zstd",
                                        ".lz4", ".lz", ".lzo", ".z", ".Z", ".br", ".uu", ".lrz", ".grz" };
    const char *b = base_name(archive);
    size_t n = strlen(b);
    for (size_t i = 0; i < sizeof exts / sizeof *exts; i++) {
        size_t m = strlen(exts[i]);
        if (n > m && strcasecmp(b + n - m, exts[i]) == 0) {
            char *r = strndup(b, n - m);
            return r;
        }
    }
    size_t len = n + 5;
    char *r = malloc(len);
    if (r) snprintf(r, len, "%s.out", b);
    return r;
}

static int is_zip_family(struct archive *a) {
    return (archive_format(a) & ARCHIVE_FORMAT_BASE_MASK) == ARCHIVE_FORMAT_ZIP;
}

static int classify_read_error(struct archive *a, const am_read_opts *o, char *err, size_t errlen) {
    const char *msg = arc_err(a);
    int has_pw = o && o->password && *o->password;
    if (strstr(msg, "Passphrase required") || (strstr(msg, "assphrase") && !has_pw)) {
        set_err(err, errlen, "%s", msg);
        return AM_NEED_PASSWORD;
    }
    if (strstr(msg, "Incorrect passphrase") || strstr(msg, "incorrect passphrases")) {
        set_err(err, errlen, "%s", msg);
        return AM_BAD_PASSWORD;
    }
    if (strstr(msg, "ncrypt") || strstr(msg, "Crypto codec")) {
        set_err(err, errlen, "%s", msg);
        return AM_UNSUPPORTED;
    }
    set_err(err, errlen, "%s", msg);
    return AM_ERR;
}

static struct archive *open_reader(const char *const *paths, int count, const am_read_opts *o, char *err,
                                   size_t errlen, int *auto_charset) {
    struct archive *a = archive_read_new();
    if (!a) { set_err(err, errlen, "out of memory"); return NULL; }
    archive_read_support_filter_all(a);
    archive_read_support_format_all(a);
    archive_read_support_format_raw(a); /* lowest bid: only used for bare .gz/.xz/... files */
    if (o && o->password && *o->password) archive_read_add_passphrase(a, o->password);
    *auto_charset = !(o && o->charset && *o->charset);
    if (!*auto_charset) {
        char opt[64];
        snprintf(opt, sizeof opt, "hdrcharset=%s", o->charset);
        archive_read_set_options(a, opt); /* modules that don't know the option just ignore it */
    }
    int r;
    if (count == 1) {
        r = archive_read_open_filename(a, paths[0], 64 * 1024);
    } else {
        const char **list = calloc((size_t)count + 1, sizeof *list);
        if (!list) { archive_read_free(a); set_err(err, errlen, "out of memory"); return NULL; }
        for (int i = 0; i < count; i++) list[i] = paths[i];
        r = archive_read_open_filenames(a, list, 64 * 1024);
        free(list);
    }
    if (r != ARCHIVE_OK) {
        set_err(err, errlen, "%s", arc_err(a));
        archive_read_free(a);
        return NULL;
    }
    return a;
}

/* A "raw" result with no decompression filter means the input isn't an archive at all. */
static int raw_without_filter(struct archive *a) {
    if (archive_format(a) != ARCHIVE_FORMAT_RAW) return 0;
    int n = archive_filter_count(a);
    for (int i = 0; i < n; i++)
        if (archive_filter_code(a, i) != ARCHIVE_FILTER_NONE) return 0;
    return 1;
}

/* ------------------------------------------------------------------ extract */

int am_extract(const char *archive, const char *dest_dir, const am_read_opts *opts,
               am_progress_cb cb, void *ctx, char *err, size_t errlen) {
    return am_extract_volumes(&archive, 1, dest_dir, opts, cb, ctx, err, errlen);
}

int am_extract_volumes(const char *const *volumes, int count, const char *dest_dir, const am_read_opts *opts,
                       am_progress_cb cb, void *ctx, char *err, size_t errlen) {
    if (count <= 0) { set_err(err, errlen, "no input"); return AM_ERR; }
    const char *archive = volumes[0];
    int64_t total = 0;
    for (int i = 0; i < count; i++) {
        struct stat st;
        if (stat(volumes[i], &st) != 0) { set_err(err, errlen, "%s: %s", base_name(volumes[i]), strerror(errno)); return AM_ERR; }
        total += st.st_size;
    }

    int auto_cs;
    struct archive *a = open_reader(volumes, count, opts, err, errlen, &auto_cs);
    if (!a) return AM_ERR;

    struct archive *ext = archive_write_disk_new();
    archive_write_disk_set_options(ext, ARCHIVE_EXTRACT_TIME | ARCHIVE_EXTRACT_SECURE_SYMLINKS |
                                            ARCHIVE_EXTRACT_SECURE_NODOTDOT);

    int has_pw = opts && opts->password && *opts->password;
    int rc = AM_OK, entries = 0;
    const void *buf;
    size_t size;
    la_int64_t offset;
    struct archive_entry *e;

    for (;;) {
        int r = archive_read_next_header(a, &e);
        if (r == ARCHIVE_EOF) break;
        if (r < ARCHIVE_WARN) { rc = classify_read_error(a, opts, err, errlen); break; }

        char *rel = NULL;
        if (archive_format(a) == ARCHIVE_FORMAT_RAW) {
            if (raw_without_filter(a)) {
                set_err(err, errlen, "Unrecognized archive format");
                rc = AM_UNSUPPORTED;
                break;
            }
            rel = raw_output_name(archive);
            archive_entry_set_filetype(e, AE_IFREG);
        } else {
            rel = entry_name_utf8(e, auto_cs);
        }
        if (!rel || !sanitize_path(rel) || is_junk_path(rel)) { free(rel); continue; }

        if (archive_entry_is_encrypted(e) && !has_pw) {
            free(rel);
            if (is_zip_family(a)) { set_err(err, errlen, "Passphrase required"); rc = AM_NEED_PASSWORD; }
            else { set_err(err, errlen, "Encrypted entries in this format are not supported"); rc = AM_UNSUPPORTED; }
            break;
        }

        char *full = path_join(dest_dir, rel);
        archive_entry_set_pathname(e, full);
        free(full);

        const char *hl = archive_entry_hardlink(e);
        if (hl) {
            char *h = strdup(hl);
            if (h && sanitize_path(h)) {
                char *hf = path_join(dest_dir, h);
                archive_entry_set_hardlink(e, hf);
                free(hf);
            } else {
                archive_entry_set_hardlink(e, NULL);
            }
            free(h);
        }

        mode_t type = archive_entry_filetype(e);
        if (type == AE_IFDIR) archive_entry_set_perm(e, 0755);
        else archive_entry_set_perm(e, (archive_entry_perm(e) & 0111) ? 0755 : 0644);
        if (type != AE_IFDIR && type != AE_IFREG && type != AE_IFLNK && !hl) { free(rel); continue; }

        if (cb && cb(ctx, archive_filter_bytes(a, -1), total, rel)) { free(rel); rc = AM_CANCELLED; break; }
        free(rel);

        r = archive_write_header(ext, e);
        if (r < ARCHIVE_WARN) { set_err(err, errlen, "%s", arc_err(ext)); rc = AM_ERR; break; }
        entries++;

        if (archive_entry_size_is_set(e) && archive_entry_size(e) == 0 && type != AE_IFREG) {
            archive_write_finish_entry(ext);
            continue;
        }
        for (;;) {
            r = archive_read_data_block(a, &buf, &size, &offset);
            if (r == ARCHIVE_EOF) break;
            if (r < ARCHIVE_WARN) { rc = classify_read_error(a, opts, err, errlen); break; }
            if (archive_write_data_block(ext, buf, size, offset) < ARCHIVE_WARN) {
                set_err(err, errlen, "%s", arc_err(ext));
                rc = AM_ERR;
                break;
            }
            if (cb && cb(ctx, archive_filter_bytes(a, -1), total, NULL)) { rc = AM_CANCELLED; break; }
        }
        if (rc != AM_OK) break;
        if (archive_write_finish_entry(ext) < ARCHIVE_WARN) {
            set_err(err, errlen, "%s", arc_err(ext));
            rc = AM_ERR;
            break;
        }
    }
    if (rc == AM_OK && cb) cb(ctx, total, total, NULL);
    archive_write_close(ext);
    archive_write_free(ext);
    archive_read_close(a);
    archive_read_free(a);
    (void)entries;
    return rc;
}

/* ------------------------------------------------------------------ list */

int am_list(const char *archive, const am_read_opts *opts, am_entry_cb cb, void *ctx,
            char *err, size_t errlen) {
    return am_list_volumes(&archive, 1, opts, cb, ctx, err, errlen);
}

int am_list_volumes(const char *const *volumes, int count, const am_read_opts *opts, am_entry_cb cb,
                    void *ctx, char *err, size_t errlen) {
    if (count <= 0) { set_err(err, errlen, "no input"); return AM_ERR; }
    const char *archive = volumes[0];
    int auto_cs;
    struct archive *a = open_reader(volumes, count, opts, err, errlen, &auto_cs);
    if (!a) return AM_ERR;
    int rc = AM_OK;
    struct archive_entry *e;
    for (;;) {
        int r = archive_read_next_header(a, &e);
        if (r == ARCHIVE_EOF) break;
        if (r < ARCHIVE_WARN) { rc = classify_read_error(a, opts, err, errlen); break; }
        char *name;
        if (archive_format(a) == ARCHIVE_FORMAT_RAW) {
            if (raw_without_filter(a)) {
                set_err(err, errlen, "Unrecognized archive format");
                rc = AM_UNSUPPORTED;
                break;
            }
            name = raw_output_name(archive);
        } else {
            name = entry_name_utf8(e, auto_cs);
        }
        if (!name || !sanitize_path(name) || is_junk_path(name)) { free(name); continue; }
        am_entry_info info = {
            .path = name,
            .size = archive_entry_size_is_set(e) ? archive_entry_size(e) : -1,
            .is_dir = archive_entry_filetype(e) == AE_IFDIR,
            .is_encrypted = archive_entry_is_encrypted(e),
        };
        int stop = cb ? cb(ctx, &info) : 0;
        free(name);
        if (stop) break;
    }
    archive_read_close(a);
    archive_read_free(a);
    return rc;
}

/* ------------------------------------------------------------------ create */

const char *am_format_extension(am_format f) {
    switch (f) {
    case AM_FMT_ZIP: return "zip";
    case AM_FMT_7Z: return "7z";
    case AM_FMT_TAR: return "tar";
    case AM_FMT_TAR_GZ: return "tar.gz";
    case AM_FMT_TAR_BZ2: return "tar.bz2";
    case AM_FMT_TAR_XZ: return "tar.xz";
    case AM_FMT_TAR_ZST: return "tar.zst";
    case AM_FMT_TAR_LZ4: return "tar.lz4";
    case AM_FMT_ISO: return "iso";
    case AM_FMT_CPIO: return "cpio";
    case AM_FMT_GZ: return "gz";
    case AM_FMT_BZ2: return "bz2";
    case AM_FMT_XZ: return "xz";
    case AM_FMT_ZST: return "zst";
    case AM_FMT_LZ4: return "lz4";
    default: return "bin";
    }
}

int am_format_is_single_file(am_format f) { return f >= AM_FMT_GZ && f <= AM_FMT_LZ4; }
int am_format_supports_password(am_format f) { return f == AM_FMT_ZIP; }

static int add_filter(struct archive *a, am_format f, int lvl, char *err, size_t errlen) {
    static const int zstd_levels[10] = { 1, 1, 2, 3, 5, 7, 9, 12, 15, 19 };
    char opt[64];
    int r = ARCHIVE_OK;
    switch (f) {
    case AM_FMT_TAR_GZ: case AM_FMT_GZ:
        r = archive_write_add_filter_gzip(a);
        snprintf(opt, sizeof opt, "gzip:compression-level=%d", lvl < 1 ? 1 : lvl);
        break;
    case AM_FMT_TAR_BZ2: case AM_FMT_BZ2:
        r = archive_write_add_filter_bzip2(a);
        snprintf(opt, sizeof opt, "bzip2:compression-level=%d", lvl < 1 ? 1 : lvl);
        break;
    case AM_FMT_TAR_XZ: case AM_FMT_XZ:
        r = archive_write_add_filter_xz(a);
        snprintf(opt, sizeof opt, "xz:compression-level=%d", lvl);
        if (r == ARCHIVE_OK) archive_write_set_filter_option(a, "xz", "threads", "0");
        break;
    case AM_FMT_TAR_ZST: case AM_FMT_ZST:
        r = archive_write_add_filter_zstd(a);
        snprintf(opt, sizeof opt, "zstd:compression-level=%d", zstd_levels[lvl]);
        if (r == ARCHIVE_OK) archive_write_set_filter_option(a, "zstd", "threads", "0");
        break;
    case AM_FMT_TAR_LZ4: case AM_FMT_LZ4:
        r = archive_write_add_filter_lz4(a);
        snprintf(opt, sizeof opt, "lz4:compression-level=%d", lvl < 1 ? 1 : lvl);
        break;
    default:
        return AM_OK;
    }
    if (r != ARCHIVE_OK) { set_err(err, errlen, "%s", arc_err(a)); return AM_ERR; }
    archive_write_set_options(a, opt);
    return AM_OK;
}

static int setup_writer(struct archive *a, const am_write_opts *o, char *err, size_t errlen) {
    int lvl = o->level < 0 ? 0 : (o->level > 9 ? 9 : o->level);
    char opt[64];
    int r = ARCHIVE_OK;
    switch (o->format) {
    case AM_FMT_ZIP:
        r = archive_write_set_format_zip(a);
        archive_write_set_options(a, "zip:hdrcharset=UTF-8");
        if (lvl == 0) {
            archive_write_set_options(a, "zip:compression=store");
        } else {
            archive_write_set_options(a, "zip:compression=deflate");
            snprintf(opt, sizeof opt, "zip:compression-level=%d", lvl);
            archive_write_set_options(a, opt);
        }
        if (o->password && *o->password && o->encryption != AM_ENC_NONE) {
            if (archive_write_set_passphrase(a, o->password) != ARCHIVE_OK ||
                archive_write_set_options(a, o->encryption == AM_ENC_ZIPCRYPTO ? "zip:encryption=zipcrypt"
                                                                                : "zip:encryption=aes256") != ARCHIVE_OK) {
                set_err(err, errlen, "%s", arc_err(a));
                return AM_ERR;
            }
        }
        break;
    case AM_FMT_7Z:
        r = archive_write_set_format_7zip(a);
        if (lvl == 0) {
            archive_write_set_options(a, "7zip:compression=store");
        } else {
            archive_write_set_options(a, "7zip:compression=lzma2");
            snprintf(opt, sizeof opt, "7zip:compression-level=%d", lvl);
            archive_write_set_options(a, opt);
        }
        break;
    case AM_FMT_TAR: case AM_FMT_TAR_GZ: case AM_FMT_TAR_BZ2: case AM_FMT_TAR_XZ:
    case AM_FMT_TAR_ZST: case AM_FMT_TAR_LZ4:
        r = archive_write_set_format_pax_restricted(a);
        break;
    case AM_FMT_ISO:
        r = archive_write_set_format_iso9660(a);
        archive_write_set_options(a, "iso9660:joliet=long,iso9660:rockridge");
        break;
    case AM_FMT_CPIO:
        r = archive_write_set_format_cpio_newc(a);
        break;
    case AM_FMT_GZ: case AM_FMT_BZ2: case AM_FMT_XZ: case AM_FMT_ZST: case AM_FMT_LZ4:
        r = archive_write_set_format_raw(a);
        break;
    default:
        set_err(err, errlen, "unknown format");
        return AM_ERR;
    }
    if (r != ARCHIVE_OK) { set_err(err, errlen, "%s", arc_err(a)); return AM_ERR; }
    return add_filter(a, o->format, lvl, err, errlen);
}

static int64_t tree_size(const char *path) {
    char *paths[2] = { (char *)path, NULL };
    FTS *fts = fts_open(paths, FTS_PHYSICAL | FTS_NOCHDIR, NULL);
    if (!fts) return 0;
    int64_t total = 0;
    FTSENT *n;
    while ((n = fts_read(fts))) {
        if (n->fts_info == FTS_F && n->fts_statp) total += n->fts_statp->st_size;
    }
    fts_close(fts);
    return total;
}

typedef struct {
    struct archive *a;
    am_progress_cb cb;
    void *ctx;
    int64_t done, total;
    char *buf;
} writer_state;

static int write_one(writer_state *w, const char *path, const char *rel, const struct stat *st,
                     char *err, size_t errlen) {
    struct archive_entry *e = archive_entry_new();
    archive_entry_copy_stat(e, st);
    archive_entry_set_pathname(e, rel);
    archive_entry_set_uid(e, 0);
    archive_entry_set_gid(e, 0);
    if (S_ISDIR(st->st_mode)) archive_entry_set_perm(e, 0755);
    else archive_entry_set_perm(e, (st->st_mode & 0111) ? 0755 : 0644);

    int fd = -1;
    if (S_ISLNK(st->st_mode)) {
        char target[4096];
        ssize_t n = readlink(path, target, sizeof target - 1);
        if (n < 0) { archive_entry_free(e); return AM_OK; }
        target[n] = '\0';
        archive_entry_set_symlink(e, target);
        archive_entry_set_size(e, 0);
    } else if (S_ISREG(st->st_mode)) {
        fd = open(path, O_RDONLY);
        if (fd < 0) {
            set_err(err, errlen, "%s: %s", rel, strerror(errno));
            archive_entry_free(e);
            return AM_ERR;
        }
    } else if (!S_ISDIR(st->st_mode)) {
        archive_entry_free(e);
        return AM_OK; /* skip sockets, fifos, devices */
    }

    if (w->cb && w->cb(w->ctx, w->done, w->total, rel)) {
        if (fd >= 0) close(fd);
        archive_entry_free(e);
        return AM_CANCELLED;
    }
    int rc = AM_OK;
    if (archive_write_header(w->a, e) < ARCHIVE_WARN) {
        set_err(err, errlen, "%s", arc_err(w->a));
        rc = AM_ERR;
    }
    while (rc == AM_OK && fd >= 0) {
        ssize_t n = read(fd, w->buf, AM_BUF_SIZE);
        if (n == 0) break;
        if (n < 0) {
            if (errno == EINTR) continue;
            set_err(err, errlen, "%s: %s", rel, strerror(errno));
            rc = AM_ERR;
            break;
        }
        if (archive_write_data(w->a, w->buf, (size_t)n) < 0) {
            set_err(err, errlen, "%s", arc_err(w->a));
            rc = AM_ERR;
            break;
        }
        w->done += n;
        if (w->cb && w->cb(w->ctx, w->done, w->total, NULL)) rc = AM_CANCELLED;
    }
    if (fd >= 0) close(fd);
    if (rc == AM_OK) archive_write_finish_entry(w->a);
    archive_entry_free(e);
    return rc;
}

int am_create(const char *output, const char *const *inputs, int count, const am_write_opts *opts,
              am_progress_cb cb, void *ctx, char *err, size_t errlen) {
    if (count <= 0) { set_err(err, errlen, "nothing to compress"); return AM_ERR; }
    if (am_format_is_single_file(opts->format)) {
        struct stat st;
        if (count != 1 || stat(inputs[0], &st) != 0 || !S_ISREG(st.st_mode)) {
            set_err(err, errlen, "This format compresses a single file only");
            return AM_UNSUPPORTED;
        }
    }

    writer_state w = { .cb = cb, .ctx = ctx };
    for (int i = 0; i < count; i++) w.total += tree_size(inputs[i]);

    w.a = archive_write_new();
    w.buf = malloc(AM_BUF_SIZE);
    if (!w.a || !w.buf) { set_err(err, errlen, "out of memory"); free(w.buf); return AM_ERR; }
    int rc = setup_writer(w.a, opts, err, errlen);
    if (rc == AM_OK && archive_write_open_filename(w.a, output) != ARCHIVE_OK) {
        set_err(err, errlen, "%s", arc_err(w.a));
        rc = AM_ERR;
    }

    for (int i = 0; rc == AM_OK && i < count; i++) {
        /* Strip trailing slashes so the stored name is the item's own name. */
        char *in = strdup(inputs[i]);
        size_t l = strlen(in);
        while (l > 1 && in[l - 1] == '/') in[--l] = '\0';
        size_t prefix = (size_t)(base_name(in) - in);

        char *paths[2] = { in, NULL };
        FTS *fts = fts_open(paths, FTS_PHYSICAL | FTS_NOCHDIR, NULL);
        if (!fts) { set_err(err, errlen, "%s: %s", in, strerror(errno)); rc = AM_ERR; free(in); break; }
        FTSENT *n;
        while (rc == AM_OK && (n = fts_read(fts))) {
            switch (n->fts_info) {
            case FTS_D: case FTS_F: case FTS_SL: case FTS_SLNONE:
                rc = write_one(&w, n->fts_path, n->fts_path + prefix, n->fts_statp, err, errlen);
                break;
            case FTS_DNR: case FTS_ERR: case FTS_NS:
                set_err(err, errlen, "%s: %s", n->fts_path, strerror(n->fts_errno));
                rc = AM_ERR;
                break;
            default:
                break;
            }
        }
        fts_close(fts);
        free(in);
    }

    if (rc == AM_OK) {
        if (archive_write_close(w.a) != ARCHIVE_OK) {
            set_err(err, errlen, "%s", arc_err(w.a));
            rc = AM_ERR;
        } else if (cb) {
            cb(ctx, w.total, w.total, NULL);
        }
    }
    archive_write_free(w.a);
    free(w.buf);
    if (rc != AM_OK) unlink(output);
    return rc;
}
