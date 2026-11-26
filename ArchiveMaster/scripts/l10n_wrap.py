"""Wraps user-visible Chinese ObjC string literals in L(...). Idempotent.
Usage: python3 l10n_wrap.py <source files...>"""
import re
import sys

LIT = re.compile(r'(?<!L\()@"((?:[^"\\\n]|\\.)*)"')
CJK = re.compile(r'[　-〿一-鿿＀-￯‘-”…]')

for path in sys.argv[1:]:
    src = open(path, encoding="utf-8").read()
    out = LIT.sub(lambda m: 'L(@"%s")' % m.group(1) if CJK.search(m.group(1)) else m.group(0), src)
    if out != src:
        open(path, "w", encoding="utf-8").write(out)
        print("wrapped", path)
