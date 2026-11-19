"""Runs the compiler (argv[1:]) on a file with invalid UTF-8 in a command-line
word and in a directory entry, and prints one verdict line per case.

The compiler must report or ignore such bytes; a crash (signal, or exit with
a trap) is the failure."""
import os, subprocess, sys, tempfile

cmd = sys.argv[1:]


def run(extra, path):
    p = subprocess.run(cmd + extra + [path], capture_output=True)
    crashed = p.returncode < 0 or p.returncode >= 128 or b"UTF-8" in p.stderr and b"trap" in p.stderr.lower()
    return "CRASH" if crashed else "OK"


with tempfile.TemporaryDirectory() as d:
    good = os.path.join(d, "a.k")
    open(good, "w").write("fn main() -> i32 { return 0 }\n")
    print("argv:", run([b"-DX\xff".decode("utf-8", "surrogateescape")], good))
    bad_dir = os.path.join(d.encode(), b"d\xff")
    os.mkdir(bad_dir)
    open(os.path.join(bad_dir, b"b.k"), "w").write("fn f() {}\n")
    print("path:", run(["-I", os.fsdecode(d)], good))
