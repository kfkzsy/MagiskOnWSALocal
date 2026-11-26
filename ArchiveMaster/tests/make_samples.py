"""Prepares test samples: decodes libarchive's .uu fixtures and crafts a ZIP whose
filenames are GBK-encoded without the UTF-8 flag (as made by Chinese Windows tools).
Usage: python3 make_samples.py <libarchive-test-dir> <out-dir>"""
import binascii
import io
import os
import sys
import zipfile

SAMPLES = [
    "test_read_format_rar.rar", "test_read_format_rar5_solid.rar",
    "test_read_format_rar5_multiple_files.rar", "test_read_format_7zip_lzma2.7z",
    "test_read_format_7zip_bcj2_lzma2_1.7z", "test_read_format_7zip_ppmd.7z",
    "test_read_format_7zip_zstd.7z", "test_read_format_cab_1.cab",
    "test_read_format_lha_lh7.lzh", "test_read_format_iso.iso.Z",
    "test_read_format_rar4_encrypted.rar", "test_read_format_7zip_encryption.7z",
] + ["test_rar_multivolume_multiple_files.part%d.rar" % i for i in range(1, 7)]


def uudecode(text):
    out = bytearray()
    for line in text.splitlines():
        if line.startswith("begin") or not line.strip():
            continue
        if line.strip() == "end":
            break
        try:
            out += binascii.a2b_uu(line)
        except binascii.Error:
            nbytes = (((ord(line[0]) - 32) & 63) * 4 + 5) // 3
            out += binascii.a2b_uu(line[:nbytes])
    return bytes(out)


def main(src, dst):
    os.makedirs(dst, exist_ok=True)
    for name in SAMPLES:
        with open(os.path.join(src, name + ".uu")) as f:
            data = uudecode(f.read())
        with open(os.path.join(dst, name), "wb") as f:
            f.write(data)

    # Placeholders have the same byte length as their GBK replacements.
    dir_gbk, file_gbk = "中文目录".encode("gbk"), "中文.txt".encode("gbk")
    dir_ph, file_ph = b"D" * len(dir_gbk), b"F" * (len(file_gbk) - 4) + b".txt"
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr(dir_ph.decode() + "/" + file_ph.decode(), "gbk named file\n")
    data = buf.getvalue().replace(dir_ph + b"/" + file_ph, dir_gbk + b"/" + file_gbk)
    with open(os.path.join(dst, "gbk.zip"), "wb") as f:
        f.write(data)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
