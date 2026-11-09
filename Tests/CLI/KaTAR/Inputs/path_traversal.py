"""Builds hostile KTAR archives by hand and checks that ktextract refuses each.

Usage: path_traversal.py <ktextract> <workdir>

Archives are written here, not by ktcompress, because the compressor only emits
clean relative names. Layout (see Extras/KaTAR/KTCompress.k):
  data (each blob + '\\n') | table (<namelen>\\n<name><offset>\\n<length>\\n)* |
  <count>\\n<table_offset>\\n
Each case prints one PASS/FAIL line so FileCheck can pin them individually.
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


def tree(root):
    out = []
    for d, dirs, files in os.walk(root):
        for n in dirs + files:
            out.append(os.path.relpath(os.path.join(d, n), root))
    return sorted(out)


def run_case(tool, work, label, entries, setup=None):
    for sub in ("dest", "outside"):
        os.makedirs(os.path.join(work, label, sub))
    case = os.path.join(work, label)
    dest = os.path.join(case, "dest")
    outside = os.path.join(case, "outside")
    if setup:
        setup(dest, outside)
    arc = os.path.join(case, "a.ktar")
    with open(arc, "wb") as f:
        f.write(build_archive(entries(case) if callable(entries) else entries))
    before = tree(case)
    p = subprocess.run([tool, arc, dest], capture_output=True, text=True)
    after = tree(case)
    created = [x for x in after if x not in before]
    problems = []
    if p.returncode == 0:
        problems.append("exit 0")
    if "refusing unsafe entry" not in p.stdout:
        problems.append("no refusal message")
    # Anything new anywhere in the case dir is a write; the only allowed new
    # paths would be under dest and refusal happens before any is made.
    if created:
        problems.append("wrote " + ",".join(created))
    print(("FAIL " if problems else "PASS ") + label + (": " + "; ".join(problems) if problems else ""))
    return not problems


def main():
    tool, work = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
    ok = True
    blob = b"pwned"

    def link_to_outside(dest, outside):
        os.symlink(outside, os.path.join(dest, "link"))

    def dangling_dir_link(dest, outside):
        os.symlink(os.path.join(outside, "not-yet"), os.path.join(dest, "link"))

    def file_link(dest, outside):
        open(os.path.join(outside, "target"), "w").write("orig")
        os.symlink(os.path.join(outside, "target"), os.path.join(dest, "f"))

    cases = [
        ("dotdot", [(b"../x", blob)], None),
        ("nested_dotdot", [(b"a/../../x", blob)], None),
        ("backslash_dotdot", [(b"a\\..\\..\\x", blob)], None),
        ("absolute", [(b"/ktar-abs-victim", blob)], None),
        ("backslash_root", [(b"\\x", blob)], None),
        ("unc", [(b"\\\\server\\share\\x", blob)], None),
        ("drive_abs", [(b"C:\\x", blob)], None),
        ("drive_relative", [(b"C:x", blob)], None),
        ("nul_byte", [(b"a\0b", blob)], None),
        ("empty_name", [(b"", blob)], None),
        # The bad entry comes second: refusal must be up front, not after "ok" is written.
        ("late_bad_entry", [(b"ok.txt", blob), (b"../x", blob)], None),
        ("symlink_dir_escape", [(b"link/pwned", blob)], link_to_outside),
        ("symlink_dangling_dir", [(b"link/sub/pwned", blob)], dangling_dir_link),
        ("symlink_file_write", [(b"f", blob)], file_link),
    ]
    for label, entries, setup in cases:
        ok &= run_case(tool, work, label, entries, setup)
    # An abs entry that would actually have escaped must not exist.
    print("PASS abs_victim_absent" if not os.path.exists("/ktar-abs-victim") else "FAIL abs_victim_absent")

    # A clean archive must still extract.
    case = os.path.join(work, "benign")
    os.makedirs(os.path.join(case, "dest"))
    arc = os.path.join(case, "a.ktar")
    with open(arc, "wb") as f:
        f.write(build_archive([(b"dir/sub/f.txt", b"hello"), (b"top.txt", b"x")]))
    p = subprocess.run([tool, arc, os.path.join(case, "dest")], capture_output=True, text=True)
    got = open(os.path.join(case, "dest", "dir", "sub", "f.txt"), "rb").read() if p.returncode == 0 else None
    print("PASS benign" if got == b"hello" else "FAIL benign: rc=%d %s" % (p.returncode, p.stdout))
    return 0


sys.exit(main())
