"""Driver for sweep_leftover_temps.k: which leftover temporaries kals removes
at start.

    python3 sweep_leftover_temps.py <Analyzer/Dev> <kals>
"""
import os
import pathlib
import shutil
import sys
import tempfile
import time

sys.path.insert(0, sys.argv[1])
from lsp_client import Client  # noqa: E402


class UriClient(Client):
    def uri(self, rel):
        return pathlib.Path(self.root, rel).as_uri()

    def start(self, options=None, progress=False, capabilities=None):
        r = self.request("initialize", {"processId": os.getpid(), "rootUri": pathlib.Path(self.root).as_uri(),
                                        "capabilities": {}, "initializationOptions": options or {}})
        self.notify("initialized", {})
        return r


def put(path, old):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write("x\n")
    if old:
        t = time.time() - 3600
        os.utime(path, (t, t))
    return path


base = tempfile.mkdtemp(prefix="kals-sweep-")
try:
    root = os.path.realpath(os.path.join(base, "root"))
    os.makedirs(root)
    put(os.path.join(root, "a.k"), False)
    cache = os.path.join(root, ".kairo", "clangd")
    gone = {
        "old .clangd temporary": put(os.path.join(root, ".clangd.tmp-1-1.tmp"), True),
        "old cache temporary": put(os.path.join(cache, "a.hh.tmp-1-2.tmp"), True),
        "old nested cache temporary": put(os.path.join(cache, "sub", "b.hh.tmp-1-3.tmp"), True),
    }
    kept = {
        "fresh .clangd temporary": put(os.path.join(root, ".clangd.tmp-2-1.tmp"), False),
        "fresh cache temporary": put(os.path.join(cache, "a.hh.tmp-2-2.tmp"), False),
        "old unrelated root file": put(os.path.join(root, "notes.tmp"), True),
        "old temporary of another root file": put(os.path.join(root, "x.json.tmp-1-1.tmp"), True),
        "old temporary in a source directory": put(os.path.join(root, "src", "m.k.tmp-1-1.tmp"), True),
    }
    c = UriClient(sys.argv[2], root)
    c.start()
    c.barrier()
    for name, p in gone.items():
        print(name + " removed:", "yes" if not os.path.exists(p) else "no")
    for name, p in kept.items():
        print(name + " kept:", "yes" if os.path.exists(p) else "no")
    print("clean shutdown:", "yes" if c.stop() == 0 else "no")
finally:
    shutil.rmtree(base, ignore_errors=True)
