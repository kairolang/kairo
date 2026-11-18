"""Writes a clean and a hostile KTAR archive and runs ktextract on each.

Usage: messages_text.py <ktextract> <workdir>

The extractor's messages carry entry names (a std::string) and the paths it
was given (C strings); each must print as text, not as the formatter's
"<type> @ <address>" fallback for a value it does not know.
"""
import os
import subprocess
import sys


def build_archive(entries):
    data = b""
    table = b""
    for name, blob in entries:
        table += b"%d\n" % len(name) + name + b"%d\n%d\n" % (len(data), len(blob))
        data += blob + b"\n"
    return data + table + b"%d\n%d\n" % (len(entries), len(data))


def main():
    tool, work = sys.argv[1], sys.argv[2]
    os.makedirs(os.path.join(work, "dest"))
    for label, entries in (("good", [(b"top.txt", b"hello")]), ("bad", [(b"../bad", b"x")])):
        arc = os.path.join(work, label + ".ktar")
        with open(arc, "wb") as f:
            f.write(build_archive(entries))
        p = subprocess.run([tool, arc, os.path.join(work, "dest")], capture_output=True, text=True)
        sys.stdout.write(p.stdout)
    p = subprocess.run([tool, os.path.join(work, "missing.ktar"), "x"], capture_output=True, text=True)
    sys.stdout.write(p.stdout)
    return 0


sys.exit(main())
