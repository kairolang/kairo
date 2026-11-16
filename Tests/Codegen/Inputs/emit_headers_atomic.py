"""Driver for emit_headers_atomic.k: runs `--emit-headers --emit-headers-layout`
twice over a changed source and reports whether the header and its prelude
were replaced whole (a hard link to the old file keeps the old bytes) and
whether any temporary is left beside them.

    python3 emit_headers_atomic.py <work dir> -- <kairo command...>
"""
import os
import subprocess
import sys

work = sys.argv[1]
cmd = sys.argv[sys.argv.index("--") + 1:]
os.makedirs(work, exist_ok=True)
src = os.path.join(work, "hdr.k")


def emit(text):
    with open(src, "w") as f:
        f.write(text)
    r = subprocess.run(cmd + ["hdr.k", "--type-check-only", "--emit-headers", "h", "--emit-headers-layout"],
                       cwd=work, capture_output=True, text=True)
    if r.returncode != 0:
        sys.stdout.write(r.stdout + r.stderr)
        sys.exit(1)


def read(p):
    with open(p, "rb") as f:
        return f.read()


v1 = "pub fn add(a: i32, b: i32) -> i32 { return a + b }\n"
v2 = "pub struct Pair {\n    pub var x: i32\n}\n\npub fn twice(v: i32) -> i32 { return v * 2 }\n\n" + v1
emit(v1)
hh = os.path.join(work, "h", "hdr.hh")
pre = hh + ".prelude"
old_h, old_p = read(hh), read(pre)
os.link(hh, os.path.join(work, "old.hh"))
os.link(pre, os.path.join(work, "old.prelude"))
emit(v2)
new_h, new_p = read(hh), read(pre)
print("header rewritten:", "yes" if b"twice" in new_h else "no")
print("old header link kept:", "yes" if read(os.path.join(work, "old.hh")) == old_h else "no")
# The prelude is only rewritten when its text changes; when it does, the
# old one must survive whole under its link as well.
print("old prelude link kept:", "yes" if new_p == old_p or read(os.path.join(work, "old.prelude")) == old_p else "no")
left = []
for d, _, files in os.walk(os.path.join(work, "h")):
    left += [f for f in files if ".tmp" in f]
print("temporaries left:", " ".join(sorted(left)) or "none")
