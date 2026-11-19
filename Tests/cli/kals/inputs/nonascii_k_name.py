"""Driver for nonascii_k_name.k: a `.k` file with a non-ASCII name that a C++
source includes still gets the clangd bridge's `.clangd` and overlay entry.

    python3 nonascii_k_name.py <Analyzer/Dev> <kals>
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

K = "pub fn doubled(n: i32) -> i32 {\n    return n * 2\n}\n"
CC = '#include "données.k"\n\nint use() { return 0; }\n'


class UriClient(Client):
    """The scripted client with percent-encoded file URIs."""

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


base = tempfile.mkdtemp(prefix="kals-nonascii-k-")
try:
    root = os.path.realpath(base)
    for name, text in (("données.k", K), ("user.cc", CC)):
        with open(os.path.join(root, name), "w", encoding="utf-8") as f:
            f.write(text)
    with open(os.path.join(root, "compile_commands.json"), "w", encoding="utf-8") as f:
        json.dump([{"directory": root, "file": "user.cc", "command": "clang++ -std=c++20 -c user.cc"}], f)
    cdp = os.path.join(root, ".clangd")

    c = UriClient(sys.argv[2], root)
    c.start()
    ok = wait_for(lambda: "-ivfsoverlay" in read(cdp), 120, c)
    print(".clangd written:", "yes" if ok else "no")
    print("source in .clangd:", "yes" if "user\\.cc" in read(cdp) else "no")
    print("clean shutdown:", "yes" if c.stop() == 0 else "no")
finally:
    shutil.rmtree(base, ignore_errors=True)
