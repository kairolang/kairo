"""Driver for unsaved_module_pin.k: a library's pin is read from the open
buffer of its module.k, not from the disk. The disk keeps `module geo`
throughout; only the buffer changes.

    python3 unsaved_module_pin.py <Analyzer/Dev> <kals>
"""
import os
import shutil
import sys
import tempfile
import time

sys.path.insert(0, sys.argv[1])
from lsp_client import Client  # noqa: E402

PIN = "module geo\n"
MAIN = "import geo::vec\n\nfn main() -> i32 {\n    return vec::one()\n}\n"


def wait_for(pred, seconds, c):
    end = time.time() + seconds
    while time.time() < end:
        if pred():
            return True
        c.pump(0.2)
    return pred()


def codes(c, rel):
    return [d["code"] for d in c.diagnostics(rel) or []]


base = tempfile.mkdtemp(prefix="kals-unsaved-pin-")
try:
    root = os.path.realpath(base)
    os.makedirs(os.path.join(root, "lib"))
    for rel, text in (("lib/module.k", PIN), ("lib/vec.k", "pub fn one() -> i32 {\n    return 1\n}\n"), ("main.k", MAIN)):
        with open(os.path.join(root, rel), "w") as f:
            f.write(text)
    with open(os.path.join(root, "kairo_compile.json"), "w") as f:
        f.write('{ "version": 1, "entries": [ { "entry": "main.k", "args": ["-I", "."] },'
                ' { "entry": "lib/module.k", "args": [] } ] }\n')

    c = Client(sys.argv[2], root)
    c.start({"debounceMs": 50})
    c.open("main.k", MAIN)
    c.open("lib/module.k", PIN)
    ok = wait_for(lambda: c.diagnostics("main.k") is not None and c.diagnostics("lib/module.k") is not None, 120, c)
    print("saved pin: module.k clean:", "yes" if ok and not codes(c, "lib/module.k") else "no")
    print("saved pin: main.k clean:", "yes" if ok and not codes(c, "main.k") else "no")

    c.change("lib/module.k", 2, "fn f() {\n}\n" + PIN)
    ok = wait_for(lambda: "R064E" in codes(c, "lib/module.k"), 120, c)
    print("unsaved late pin: module.k R064E:", "yes" if ok else "no")

    c.change("lib/module.k", 3, "module geo2\n")
    ok = wait_for(lambda: "R064E" not in codes(c, "lib/module.k"), 120, c)
    print("unsaved rename: module.k clean:", "yes" if ok and not codes(c, "lib/module.k") else "no")
    ok = wait_for(lambda: "R011E" in codes(c, "main.k"), 120, c)
    print("unsaved rename: main.k import fails:", "yes" if ok else "no")

    c.change("lib/module.k", 4, PIN)
    ok = wait_for(lambda: not codes(c, "main.k") and not codes(c, "lib/module.k"), 120, c)
    print("buffer restored: module.k clean:", "yes" if ok and not codes(c, "lib/module.k") else "no")
    print("buffer restored: main.k clean:", "yes" if ok and not codes(c, "main.k") else "no")
    print("clean shutdown:", "yes" if c.stop() == 0 else "no")
finally:
    shutil.rmtree(base, ignore_errors=True)
