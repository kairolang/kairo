"""Driver for multibyte_text.k: kals reads and writes non-ASCII text whole.
The project directory, the name of a C++ source that includes a `.k`, and
the `.k` file's doc comments and declarations hold multibyte UTF-8; the
clangd bridge's `.clangd` and the hovers carry them through unchanged.

    python3 multibyte_text.py <Analyzer/Dev> <kals>
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

K = ("/// Größe in Zoll ☃.\n"
     "pub fn größe(n: i32) -> i32 {\n"
     "    return n * 2\n"
     "}\n"
     "\n"
     "/// Ein Café, naïve.\n"
     "pub class Café {\n"
     "    var preis: i32\n"
     "}\n")
CC = '#include "donnees.k"\n\nint use() { return 0; }\n'
MARK = ("# Written by kals, the Kairo language server: clangd reads Kairo headers"
        " through it. Remove this line to keep your own edits.")


class UriClient(Client):
    """The scripted client with percent-encoded file URIs."""

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


def hover(c, line, ch):
    r = c.request("textDocument/hover", c.at("donnees.k", line, ch))
    if not r:
        return "(none)"
    v = r.get("contents", {})
    v = v.get("value", "") if isinstance(v, dict) else str(v)
    return " | ".join(x for x in v.splitlines() if x.strip())


base = tempfile.mkdtemp(prefix="kals-multibyte-")
try:
    root = os.path.realpath(os.path.join(base, "projé ☃"))
    os.makedirs(root)
    for name, text in (("donnees.k", K), ("bé.cc", CC)):
        with open(os.path.join(root, name), "w", encoding="utf-8") as f:
            f.write(text)
    with open(os.path.join(root, "compile_commands.json"), "w", encoding="utf-8") as f:
        json.dump([{"directory": root, "file": "bé.cc", "command": "clang++ -std=c++20 -c bé.cc"}], f,
                  ensure_ascii=False)
    cdp = os.path.join(root, ".clangd")
    # A fragment kals wrote before (its marker line): kals rewrites it.
    with open(cdp, "w", newline="") as f:
        f.write(MARK + "\nstale fragment\n")

    c = UriClient(sys.argv[2], root)
    c.start()
    ok = wait_for(lambda: "-ivfsoverlay" in read(cdp), 120, c)
    print(".clangd written:", "yes" if ok else "no")
    for line in read(cdp).splitlines():
        if "PathMatch" in line:
            print("clangd:", line.strip())
    print("root in .clangd:", "yes" if root in read(cdp) else "no")

    c.open("donnees.k", K)
    ok = wait_for(lambda: c.diagnostics("donnees.k") is not None, 120, c)
    print("diagnostics:", len(c.diagnostics("donnees.k") or []) if ok else "none published")
    print("hover fn:", hover(c, 1, 8))
    print("hover class:", hover(c, 6, 11))
    print("clean shutdown:", "yes" if c.stop() == 0 else "no")
finally:
    shutil.rmtree(base, ignore_errors=True)
