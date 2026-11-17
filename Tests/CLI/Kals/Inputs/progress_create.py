"""Driver for progress_create.k: when kals may use a work-done progress
token. The first client holds its answer to `window/workDoneProgress/create`
back until the test releases it; the second answers with an error.

    python3 progress_create.py <Analyzer/Dev> <kals>
"""
import os
import shutil
import sys
import tempfile
import time

sys.path.insert(0, sys.argv[1])
from lsp_client import Client  # noqa: E402

MAIN = "fn main() -> i32 {\n    return 0\n}\n"


class Held(Client):
    """Holds the answer to a create until `release`."""

    def __init__(self, *a, **k):
        super().__init__(*a, **k)
        self.held = []

    def answer(self, m):
        if m["method"] == "window/workDoneProgress/create":
            self.held.append(m)
        else:
            super().answer(m)

    def release(self):
        for m in self.held:
            self.send({"jsonrpc": "2.0", "id": m["id"], "result": None})
        self.held = []


class Refusing(Client):
    def answer(self, m):
        if m["method"] == "window/workDoneProgress/create":
            self.send({"jsonrpc": "2.0", "id": m["id"], "error": {"code": -32601, "message": "no progress here"}})
        else:
            super().answer(m)


def project(base):
    os.makedirs(os.path.join(base, "src"))
    with open(os.path.join(base, "src", "main.k"), "w") as f:
        f.write(MAIN)
    with open(os.path.join(base, "kairo_compile.json"), "w") as f:
        f.write('{ "version": 1, "entries": [ { "entry": "src/main.k", "args": ["-I", "src"] } ] }\n')


def wait_for(pred, seconds, c):
    end = time.time() + seconds
    while time.time() < end:
        if pred():
            return True
        c.pump(0.1)
    return pred()


def kinds(c, token=None):
    return [n["params"]["value"]["kind"] for n in c.notes
            if n["method"] == "$/progress" and (token is None or n["params"]["token"] == token)]


def made(c):
    return [n for n in c.notes if n["method"] == "window/workDoneProgress/create"]


def analysed(c):
    return any(n["method"] == "$/kals/analysed" for n in c.notes)


base = tempfile.mkdtemp(prefix="kals-progress-create-")
try:
    root = os.path.realpath(os.path.join(base, "late"))
    project(root)
    # The index is held back, so the run outlasts the withheld answer.
    c = Held(sys.argv[2], root, env={"KALS_DEBUG_INDEX_DELAY_MS": "1500"})
    c.start({"debounceMs": 50}, progress=True)
    c.open("src/main.k", MAIN)
    ok = wait_for(lambda: made(c), 30, c)
    print("created:", "yes" if ok else "no")
    c.pump(2.5)
    print("progress before the answer:", " ".join(kinds(c)) or "none")
    token = made(c)[0]["params"]["token"]
    c.release()
    wait_for(lambda: "end" in kinds(c, token), 60, c)
    k = kinds(c, token)
    print("begin after the answer:", "yes" if k[:1] == ["begin"] else "no")
    print("end after begin:", "yes" if "end" in k and k.index("end") > 0 else "no")
    c.stop()

    root = os.path.realpath(os.path.join(base, "refused"))
    project(root)
    c = Refusing(sys.argv[2], root)
    c.start({"debounceMs": 50}, progress=True)
    c.open("src/main.k", MAIN)
    ok = wait_for(lambda: made(c), 30, c)
    print("refused: created:", "yes" if ok else "no")
    ok = wait_for(lambda: analysed(c), 120, c)
    c.settle()
    print("refused: progress:", " ".join(kinds(c)) or "none")
    print("refused: analysed:", "yes" if ok else "no")
    print("clean shutdown:", "yes" if c.stop() == 0 else "no")
finally:
    shutil.rmtree(base, ignore_errors=True)
