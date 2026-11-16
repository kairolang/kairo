"""Driver for bridge_atomic.k: kals' clangd bridge replaces `.clangd` and a
`.k` file's header whole. A hard link taken to each before kals rewrites it
must keep the old bytes (a rename put a new file in its place; a write in
place would have changed the linked file too), and no temporary is left in
the project or the bridge's cache.

    python3 bridge_atomic.py <Analyzer/Dev> <kals>
"""
import json
import os
import pathlib
import shutil
import sys
import tempfile
import time

sys.path.insert(0, sys.argv[1])
from lsp_client import Client  # noqa: E402

MARK = ("# Written by kals, the Kairo language server: clangd reads Kairo headers"
        " through it. Remove this line to keep your own edits.")
STALE = MARK + "\nstale fragment\n"
A = "/// Adds.\npub fn add(a: i32, b: i32) -> i32 {\n    return a + b\n}\n"
B = '#include "a.k"\n\nint use() { return a::add(1, 2); }\n'


class UriClient(Client):
    """The scripted client with file URIs every platform reads."""

    def uri(self, rel):
        return pathlib.Path(self.root, rel).as_uri()

    def start(self, options=None, progress=False, capabilities=None):
        r = self.request("initialize", {"processId": os.getpid(), "rootUri": pathlib.Path(self.root).as_uri(),
                                        "capabilities": {}, "initializationOptions": options or {}})
        self.notify("initialized", {})
        return r


def read(p):
    try:
        with open(p, "rb") as f:
            return f.read().decode("utf-8", "replace")
    except OSError:
        return ""


def wait_for(pred, seconds, c):
    end = time.time() + seconds
    while time.time() < end:
        if pred():
            return True
        c.pump(0.2)
    return pred()


def temporaries(*dirs):
    out = []
    for d in dirs:
        if os.path.isdir(d):
            out += [n for n in os.listdir(d) if ".tmp" in n]
    return sorted(out)


base = tempfile.mkdtemp(prefix="kals-bridge-atomic-")
try:
    root = os.path.realpath(os.path.join(base, "root"))
    links = os.path.join(base, "links")
    os.makedirs(root)
    os.makedirs(links)
    for name, text in (("a.k", A), ("b.cc", B)):
        with open(os.path.join(root, name), "w") as f:
            f.write(text)
    with open(os.path.join(root, "compile_commands.json"), "w") as f:
        json.dump([{"directory": root, "file": "b.cc", "command": "clang++ -std=c++20 -c b.cc"}], f)
    cdp = os.path.join(root, ".clangd")
    # A fragment kals wrote before (its marker line) that no longer says
    # what it would: kals rewrites it.
    with open(cdp, "w", newline="") as f:
        f.write(STALE)
    os.link(cdp, os.path.join(links, "clangd"))
    cache = os.path.join(root, ".kairo", "clangd")
    hdr = os.path.join(cache, "a.hh")

    c = UriClient(sys.argv[2], root)
    c.start()
    ok = wait_for(lambda: os.path.exists(hdr) and "-ivfsoverlay" in read(cdp), 120, c)
    print(".clangd rewritten:", "yes" if ok else "no")
    print("old .clangd link kept:", "yes" if read(os.path.join(links, "clangd")) == STALE else "no")

    old_h = read(hdr)
    os.link(hdr, os.path.join(links, "a.hh"))
    c.open("a.k", A)
    c.change("a.k", 2, "pub fn twice(v: i32) -> i32 {\n    return v * 2\n}\n\n" + A)
    ok = wait_for(lambda: "twice(signed int v)" in read(hdr), 120, c)
    print("header rewritten:", "yes" if ok else "no")
    print("old header link kept:", "yes" if read(os.path.join(links, "a.hh")) == old_h else "no")
    print("temporaries left:", " ".join(temporaries(root, cache)) or "none")
    print("clean shutdown:", "yes" if c.stop() == 0 else "no")
finally:
    shutil.rmtree(base, ignore_errors=True)
