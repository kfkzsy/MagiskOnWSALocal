"""Localization helper.
  l10n_check.py keys <sources...>                 print every L(@"...") key (unescaped), one JSON string per line
  l10n_check.py check <strings-file> <sources...> verify the .strings file covers all keys with matching format specifiers
  l10n_check.py compile <strings-file> <out>      write the .strings file as a binary plist"""
import json
import plistlib
import re
import sys

KEY = re.compile(r'L\(@"((?:[^"\\\n]|\\.)*)"\)')
SPEC = re.compile(r'%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j)?[@dDuUxXoOfeEgGcCsSpaA%]')


def unescape(s):
    return re.sub(r'\\(.)', lambda m: {"n": "\n", "t": "\t"}.get(m.group(1), m.group(1)), s)


def keys(paths):
    out = []
    for p in paths:
        for m in KEY.finditer(open(p, encoding="utf-8").read()):
            k = unescape(m.group(1))
            if k not in out:
                out.append(k)
    return out


def parse_strings(path):
    """Parses the "key" = "value"; text format (with // and /* */ comments)."""
    text = open(path, encoding="utf-8").read()
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    text = re.sub(r'^\s*//.*$', '', text, flags=re.M)
    pair = re.compile(r'"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;')
    table = {}
    for m in pair.finditer(text):
        table[unescape(m.group(1))] = unescape(m.group(2))
    return table


def specs(s):
    return [x for x in SPEC.findall(s) if x != "%%"]


def main():
    cmd = sys.argv[1]
    if cmd == "keys":
        for k in keys(sys.argv[2:]):
            print(json.dumps(k, ensure_ascii=False))
    elif cmd == "check":
        table = parse_strings(sys.argv[2])
        bad = 0
        for k in keys(sys.argv[3:]):
            if k not in table:
                print("missing:", json.dumps(k, ensure_ascii=False)); bad += 1
            elif specs(k) != specs(table[k]):
                print("format mismatch:", json.dumps(k, ensure_ascii=False), "->", json.dumps(table[k])); bad += 1
        print("%d keys, %d problems" % (len(keys(sys.argv[3:])), bad))
        sys.exit(1 if bad else 0)
    elif cmd == "compile":
        with open(sys.argv[3], "wb") as f:
            plistlib.dump(parse_strings(sys.argv[2]), f, fmt=plistlib.FMT_BINARY)


if __name__ == "__main__":
    main()
