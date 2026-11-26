// Host-side tests for AMArchiveCore. Build with tests/run_host_tests.sh.
// Usage: test_core <work-dir> <samples-dir>
#include "../Sources/AMArchiveCore.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int failures = 0;
static char W[1024];

#define CHECK(cond, ...) do { if (!(cond)) { failures++; printf("  FAIL %s:%d: ", __FILE__, __LINE__); \
    printf(__VA_ARGS__); printf("\n"); } } while (0)

static int sh(const char *fmt, ...) {
    char cmd[4096];
    va_list ap; va_start(ap, fmt); vsnprintf(cmd, sizeof cmd, fmt, ap); va_end(ap);
    return system(cmd);
}

static void fresh_dir(const char *p) { sh("rm -rf '%s' && mkdir -p '%s'", p, p); }

static int count_cb(void *ctx, int64_t done, int64_t total, const char *name) {
    (void)name;
    int *calls = ctx; (*calls)++;
    if (done < 0 || total < 0 || done > total) { printf("  bad progress %lld/%lld\n", (long long)done, (long long)total); failures++; }
    return 0;
}

static int cancel_cb(void *ctx, int64_t done, int64_t total, const char *name) {
    (void)ctx; (void)total; (void)name;
    return done > 200 * 1024;
}

static void make_tree(void) {
    char p[1200];
    snprintf(p, sizeof p, "%s/src", W); fresh_dir(p);
    sh("mkdir -p '%s/src/测试文件夹/子目录/空目录' && printf 'hello 你好\\n' > '%s/src/测试文件夹/子目录/文本.txt'", W, W);
    sh("head -c 1500000 /dev/urandom > '%s/src/测试文件夹/random.bin'", W);
    sh("yes 'compressible line of text' | head -c 2000000 > '%s/src/测试文件夹/big.txt'", W);
    sh("printf 'single file contents 单文件\\n' > '%s/src/单个文件.txt'", W);
}

static void test_roundtrip(am_format fmt) {
    char out[1200], dest[1200], in1[1200], in2[1200], err[512] = "";
    snprintf(out, sizeof out, "%s/out.%s", W, am_format_extension(fmt));
    snprintf(dest, sizeof dest, "%s/x_%s", W, am_format_extension(fmt));
    snprintf(in1, sizeof in1, "%s/src/测试文件夹", W);
    snprintf(in2, sizeof in2, "%s/src/单个文件.txt", W);
    const char *inputs[] = { in1, in2 };
    unlink(out);
    fresh_dir(dest);
    am_write_opts wo = { .format = fmt, .level = 6 };
    int calls = 0;
    int rc = am_create(out, inputs, 2, &wo, count_cb, &calls, err, sizeof err);
    CHECK(rc == AM_OK, "create %s rc=%d err=%s", am_format_extension(fmt), rc, err);
    CHECK(calls > 0, "no progress callbacks");
    struct stat st; stat(out, &st);
    rc = am_extract(out, dest, NULL, count_cb, &calls, err, sizeof err);
    CHECK(rc == AM_OK, "extract %s rc=%d err=%s", am_format_extension(fmt), rc, err);
    int d = sh("diff -r '%s/src' '%s' >/dev/null", W, dest);
    CHECK(d == 0, "content differs for %s", am_format_extension(fmt));
    printf("  %-8s ok  (%lld bytes)\n", am_format_extension(fmt), (long long)st.st_size);
}

static void test_single(am_format fmt) {
    char out[1200], dest[1200], in[1200], err[512] = "";
    snprintf(in, sizeof in, "%s/src/单个文件.txt", W);
    snprintf(out, sizeof out, "%s/单个文件.txt.%s", W, am_format_extension(fmt));
    snprintf(dest, sizeof dest, "%s/s_%s", W, am_format_extension(fmt));
    fresh_dir(dest);
    const char *inputs[] = { in };
    am_write_opts wo = { .format = fmt, .level = 9 };
    int rc = am_create(out, inputs, 1, &wo, NULL, NULL, err, sizeof err);
    CHECK(rc == AM_OK, "create single %s rc=%d %s", am_format_extension(fmt), rc, err);
    rc = am_extract(out, dest, NULL, NULL, NULL, err, sizeof err);
    CHECK(rc == AM_OK, "extract single %s rc=%d %s", am_format_extension(fmt), rc, err);
    CHECK(sh("cmp -s '%s' '%s/单个文件.txt'", in, dest) == 0, "single %s mismatch", am_format_extension(fmt));
    printf("  %-8s single-file ok\n", am_format_extension(fmt));

    // directories are rejected for single-file formats
    char dir[1200]; snprintf(dir, sizeof dir, "%s/src/测试文件夹", W);
    const char *bad[] = { dir };
    rc = am_create(out, bad, 1, &wo, NULL, NULL, err, sizeof err);
    CHECK(rc == AM_UNSUPPORTED, "dir accepted by single-file format");
}

static void test_password(am_encryption enc) {
    char out[1200], dest[1200], in[1200], err[512] = "";
    snprintf(in, sizeof in, "%s/src/测试文件夹", W);
    snprintf(out, sizeof out, "%s/enc%d.zip", W, (int)enc);
    snprintf(dest, sizeof dest, "%s/enc%d", W, (int)enc);
    const char *inputs[] = { in };
    am_write_opts wo = { .format = AM_FMT_ZIP, .level = 5, .password = "秘密pass", .encryption = enc };
    int rc = am_create(out, inputs, 1, &wo, NULL, NULL, err, sizeof err);
    CHECK(rc == AM_OK, "create encrypted rc=%d %s", rc, err);

    fresh_dir(dest);
    rc = am_extract(out, dest, NULL, NULL, NULL, err, sizeof err);
    CHECK(rc == AM_NEED_PASSWORD, "no password: rc=%d %s", rc, err);

    fresh_dir(dest);
    am_read_opts bad = { .password = "wrong" };
    rc = am_extract(out, dest, &bad, NULL, NULL, err, sizeof err);
    CHECK(rc == AM_BAD_PASSWORD, "wrong password: rc=%d %s", rc, err);

    fresh_dir(dest);
    am_read_opts good = { .password = "秘密pass" };
    rc = am_extract(out, dest, &good, NULL, NULL, err, sizeof err);
    CHECK(rc == AM_OK, "right password: rc=%d %s", rc, err);
    CHECK(sh("diff -r '%s' '%s/测试文件夹' >/dev/null", in, dest) == 0, "encrypted content differs");
    printf("  zip %s password ok\n", enc == AM_ENC_AES256 ? "AES-256" : "ZipCrypto");
}

static int only_text(void *ctx, const char *path) {
    (void)ctx;
    return strcmp(path, "测试文件夹/子目录/文本.txt") == 0;
}

static void test_filter_and_passwords(void) {
    char out[1200], dest[1200], in[1200], err[512] = "";
    snprintf(in, sizeof in, "%s/src/测试文件夹", W);
    snprintf(out, sizeof out, "%s/multi.zip", W);
    snprintf(dest, sizeof dest, "%s/multi", W);
    const char *inputs[] = { in };
    am_write_opts wo = { .format = AM_FMT_ZIP, .level = 1, .password = "right", .encryption = AM_ENC_AES256 };
    int rc = am_create(out, inputs, 1, &wo, NULL, NULL, err, sizeof err);
    CHECK(rc == AM_OK, "create rc=%d", rc);

    // A saved list where only the last candidate is right.
    const char *book[] = { "nope", "also-wrong", "right" };
    am_read_opts ro = { .passwords = book, .password_count = 3 };
    fresh_dir(dest);
    rc = am_extract(out, dest, &ro, NULL, NULL, err, sizeof err);
    CHECK(rc == AM_OK, "password list rc=%d %s", rc, err);
    CHECK(sh("diff -r '%s' '%s/测试文件夹' >/dev/null", in, dest) == 0, "password list content differs");

    // All candidates wrong -> bad password.
    am_read_opts bad = { .passwords = book, .password_count = 2 };
    fresh_dir(dest);
    rc = am_extract(out, dest, &bad, NULL, NULL, err, sizeof err);
    CHECK(rc == AM_BAD_PASSWORD, "all-wrong list rc=%d", rc);

    // Selective extraction of one entry.
    am_read_opts sel = { .password = "right", .include = only_text };
    fresh_dir(dest);
    rc = am_extract(out, dest, &sel, NULL, NULL, err, sizeof err);
    CHECK(rc == AM_OK, "filter rc=%d %s", rc, err);
    CHECK(sh("test -f '%s/测试文件夹/子目录/文本.txt' && test ! -e '%s/测试文件夹/big.txt'", dest, dest) == 0, "filter extracted wrong set");
    printf("  password list + selective extract ok\n");
}

static void test_cancel(void) {
    char out[1200], in[1200], err[512] = "";
    snprintf(in, sizeof in, "%s/src/测试文件夹", W);
    snprintf(out, sizeof out, "%s/cancel.zip", W);
    const char *inputs[] = { in };
    am_write_opts wo = { .format = AM_FMT_ZIP, .level = 1 };
    int rc = am_create(out, inputs, 1, &wo, cancel_cb, NULL, err, sizeof err);
    CHECK(rc == AM_CANCELLED, "cancel rc=%d", rc);
    CHECK(access(out, F_OK) != 0, "cancelled output not removed");
    printf("  cancel ok\n");
}

static void test_not_archive(void) {
    char in[1200], dest[1200], err[512] = "";
    snprintf(in, sizeof in, "%s/src/单个文件.txt", W);
    snprintf(dest, sizeof dest, "%s/na", W);
    fresh_dir(dest);
    int rc = am_extract(in, dest, NULL, NULL, NULL, err, sizeof err);
    CHECK(rc == AM_UNSUPPORTED, "plain text treated as archive rc=%d", rc);
    printf("  non-archive rejected ok\n");
}

static int list_cb(void *ctx, const am_entry_info *info) {
    int *n = ctx; (*n)++;
    if (getenv("VERBOSE")) printf("    %s %lld%s\n", info->path, (long long)info->size, info->is_dir ? " [dir]" : "");
    return 0;
}

static void test_sample(const char *samples, const char *name, int expect) {
    char path[1200], dest[1200], err[512] = "";
    snprintf(path, sizeof path, "%s/%s", samples, name);
    snprintf(dest, sizeof dest, "%s/sample", W);
    fresh_dir(dest);
    int n = 0;
    int lr = am_list(path, NULL, list_cb, &n, err, sizeof err);
    int rc = am_extract(path, dest, NULL, NULL, NULL, err, sizeof err);
    CHECK(rc == expect, "%s: rc=%d (want %d) err=%s", name, rc, expect, err);
    printf("  sample %-48s rc=%d list=%d entries=%d %s\n", name, rc, lr, n, rc ? err : "");
}

static void test_gbk(const char *samples) {
    char path[1200], dest[1200], err[512] = "";
    snprintf(path, sizeof path, "%s/gbk.zip", samples);
    snprintf(dest, sizeof dest, "%s/gbk", W);
    fresh_dir(dest);
    int rc = am_extract(path, dest, NULL, NULL, NULL, err, sizeof err);
    CHECK(rc == AM_OK, "gbk extract rc=%d %s", rc, err);
    char want[1300]; snprintf(want, sizeof want, "%s/中文目录/中文.txt", dest);
    CHECK(access(want, F_OK) == 0, "GBK names not decoded");
    fresh_dir(dest);
    am_read_opts ro = { .charset = "CP936" };
    rc = am_extract(path, dest, &ro, NULL, NULL, err, sizeof err);
    CHECK(rc == AM_OK && access(want, F_OK) == 0, "forced CP936 failed rc=%d %s", rc, err);
    printf("  GBK filename detection ok\n");
}

static void test_volumes(const char *samples) {
    char err[512] = "", dest[1200], parts[6][1200];
    const char *vols[6];
    for (int i = 0; i < 6; i++) {
        snprintf(parts[i], sizeof parts[i], "%s/test_rar_multivolume_multiple_files.part%d.rar", samples, i + 1);
        vols[i] = parts[i];
    }
    snprintf(dest, sizeof dest, "%s/vol_rar", W);
    fresh_dir(dest);
    int n = 0;
    int rc = am_list_volumes(vols, 6, NULL, list_cb, &n, err, sizeof err);
    CHECK(rc == AM_OK && n > 0, "list rar volumes rc=%d n=%d %s", rc, n, err);
    rc = am_extract_volumes(vols, 6, dest, NULL, NULL, NULL, err, sizeof err);
    CHECK(rc == AM_OK, "extract rar volumes rc=%d %s", rc, err);
    printf("  rar multi-volume (6 parts, %d entries) ok\n", n);

    // A 7z split into raw chunks (x.7z.001, x.7z.002, ...) as produced by 7-Zip's "split to volumes".
    char out[1200], in[1200];
    snprintf(in, sizeof in, "%s/src/测试文件夹", W);
    snprintf(out, sizeof out, "%s/split.7z", W);
    const char *inputs[] = { in };
    am_write_opts wo = { .format = AM_FMT_7Z, .level = 1 };
    rc = am_create(out, inputs, 1, &wo, NULL, NULL, err, sizeof err);
    CHECK(rc == AM_OK, "create split src rc=%d", rc);
    sh("cd '%s' && rm -f split.7z.0* && split -b 400000 -d -a 3 --numeric-suffixes=1 split.7z split.7z.", W);
    char chunks[16][1200]; const char *cv[16]; int nc = 0;
    for (int i = 1; i < 16; i++) {
        snprintf(chunks[nc], sizeof chunks[nc], "%s/split.7z.%03d", W, i);
        if (access(chunks[nc], F_OK) != 0) break;
        cv[nc] = chunks[nc]; nc++;
    }
    snprintf(dest, sizeof dest, "%s/vol_7z", W);
    fresh_dir(dest);
    rc = am_extract_volumes(cv, nc, dest, NULL, NULL, NULL, err, sizeof err);
    CHECK(rc == AM_OK, "extract split 7z rc=%d %s", rc, err);
    CHECK(sh("diff -r '%s' '%s/测试文件夹' >/dev/null", in, dest) == 0, "split 7z content differs");
    printf("  split 7z (%d parts) ok\n", nc);
}

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: %s work samples\n", argv[0]); return 2; }
    am_init();
    snprintf(W, sizeof W, "%s", argv[1]);
    make_tree();
    printf("round trips:\n");
    for (am_format f = AM_FMT_ZIP; f <= AM_FMT_CPIO; f++) test_roundtrip(f);
    printf("single file:\n");
    for (am_format f = AM_FMT_GZ; f <= AM_FMT_LZ4; f++) test_single(f);
    printf("misc:\n");
    test_password(AM_ENC_AES256);
    test_password(AM_ENC_ZIPCRYPTO);
    test_filter_and_passwords();
    test_cancel();
    test_not_archive();
    test_gbk(argv[2]);
    test_volumes(argv[2]);
    printf("samples:\n");
    test_sample(argv[2], "test_read_format_rar.rar", AM_OK);
    test_sample(argv[2], "test_read_format_rar5_solid.rar", AM_OK);
    test_sample(argv[2], "test_read_format_rar5_multiple_files.rar", AM_OK);
    test_sample(argv[2], "test_read_format_7zip_lzma2.7z", AM_OK);
    test_sample(argv[2], "test_read_format_7zip_bcj2_lzma2_1.7z", AM_OK);
    test_sample(argv[2], "test_read_format_7zip_ppmd.7z", AM_OK);
    test_sample(argv[2], "test_read_format_7zip_zstd.7z", AM_OK);
    test_sample(argv[2], "test_read_format_cab_1.cab", AM_OK);
    test_sample(argv[2], "test_read_format_lha_lh7.lzh", AM_OK);
    test_sample(argv[2], "test_read_format_iso.iso.Z", AM_OK);
    test_sample(argv[2], "test_read_format_rar4_encrypted.rar", AM_UNSUPPORTED);
    test_sample(argv[2], "test_read_format_7zip_encryption.7z", AM_UNSUPPORTED);
    printf(failures ? "\n%d FAILURE(S)\n" : "\nALL TESTS PASSED\n", failures);
    return failures != 0;
}
