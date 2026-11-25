"""Compiles a small program again and again while another thread rewrites one
of its imported files, in place (truncate and write) and by rename, between
two valid texts of very different lengths. Prints how the compiles ended.

A compile that read the file half written may report syntax errors; none may
crash, and one that succeeds builds a program from one text or the other.

Usage: source_rewritten_during_build.py <kairo> <work dir> <compiles> <seconds>"""
import os, shutil, subprocess, sys, threading, time
from pathlib import Path

kairo, work, want, budget = sys.argv[1], Path(sys.argv[2]), int(sys.argv[3]), float(sys.argv[4])
shutil.rmtree(work, ignore_errors=True)
work.mkdir(parents=True)

SHORT = "pub fn value() -> i32 = 7\n"
LONG = ("// padding to move every offset after it\n" * 60
        + "pub fn value() -> i32 {\n"
        + "    var a_rather_long_local_name = 40\n"
        + "    return a_rather_long_local_name + 2\n"
        + "}\n")
(work / "a.k").write_text(LONG)
(work / "b.k").write_text("import a\n\npub fn twice() -> i32 {\n    return a::value() + a::value()\n}\n")
(work / "main.k").write_text("import a\nimport b\n\nfn main() -> i32 {\n    return b::twice() - a::value()\n}\n")

stop = threading.Event()


def editor():
    k = 0
    p = work / "a.k"
    while not stop.is_set():
        text = SHORT if k % 2 == 0 else LONG
        if k % 4 < 2:
            p.write_text(text)
        else:
            tmp = work / "a.k.tmp"
            tmp.write_text(text)
            os.replace(tmp, p)
        k += 1
        time.sleep(0.001)


th = threading.Thread(target=editor)
th.start()
counts = {"ok": 0, "error": 0, "ice": 0, "signal": 0, "wrong": 0}
start = time.time()
n = 0
try:
    while n < want and time.time() - start < budget:
        exe = work / "x.exe"
        exe.unlink(missing_ok=True)
        r = subprocess.run([kairo, "main.k", "-I", ".", "-o", str(exe)], cwd=work,
                           capture_output=True, text=True, timeout=300)
        out = r.stdout + r.stderr
        n += 1
        if r.returncode < 0:
            counts["signal"] += 1
            print(f"compile {n}: signal {-r.returncode}\n{out[-1500:]}")
        elif "Internal Compiler Error" in out:
            counts["ice"] += 1
            print(f"compile {n}: ice\n{out[-1500:]}")
        elif r.returncode != 0:
            counts["error"] += 1
        else:
            rc = subprocess.run([str(exe)]).returncode
            if rc in (7, 42):
                counts["ok"] += 1
            else:
                counts["wrong"] += 1
                print(f"compile {n}: the program returned {rc}")
finally:
    stop.set()
    th.join()

print("compiles " + ("some" if n > 0 else "none"))
for k in ("signal", "ice", "wrong"):
    print(f"{k} {counts[k]}")

# The file left as it is: the compile succeeds and the program is the text's.
(work / "a.k").write_text(SHORT)
exe = work / "x.exe"
exe.unlink(missing_ok=True)
r = subprocess.run([kairo, "main.k", "-I", ".", "-o", str(exe)], cwd=work, capture_output=True, text=True)
print(f"quiet compile {r.returncode}")
print(f"quiet run {subprocess.run([str(exe)]).returncode if r.returncode == 0 else 'none'}")
