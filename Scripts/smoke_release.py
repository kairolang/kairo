#!/usr/bin/env python3
"""Smoke-tests an UNPACKED release archive with a stripped environment.

    python3 Scripts/smoke_release.py build/ship/fresh [--scratch DIR]

Environment is only PATH=<tree>/bin:/usr/bin:/bin (no KAIRO_* variables). Cases: Kairo
hello, C and C++ hello through kcc, the README's mixed packet.k/main.cpp, cross links (no
run), a llvm-ar static library, the Apple refusal, and (with strace) a check that nothing
execs clang or ld.lld. Prints a table; exit 1 if any case other than the documented
Apple one fails.
"""
import argparse
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("tree")
    ap.add_argument("--scratch", default=str(ROOT / "build" / "ship" / "smoke"))
    a = ap.parse_args()
    tree = Path(a.tree).resolve()
    sc = Path(a.scratch).resolve()
    shutil.rmtree(sc, ignore_errors=True)
    sc.mkdir(parents=True)
    env = {"PATH": f"{tree}/bin:/usr/bin:/bin", "HOME": str(sc)}
    readme = (ROOT / "README.md").read_text()
    (sc / "hello.k").write_text('import std::io\n\nfn main() -> i32 {\n    io::println("Hello from Kairo")\n    return 0\n}\n')
    (sc / "h.c").write_text('#include <stdio.h>\nint main(void){ puts("hello c"); return 0; }\n')
    (sc / "h.cc").write_text('#include <iostream>\nint main(){ std::cout << "hello c++\\n"; return 0; }\n')
    (sc / "lib.c").write_text("int add(int a,int b){return a+b;}\n")
    (sc / "m.c").write_text('#include <stdio.h>\nint add(int,int);\nint main(void){ printf("%d\\n", add(2,3)); return 0; }\n')
    for name in ("main.cpp", "packet.k"):
        m = re.search(r"```\w*\n//> " + re.escape(name) + r"\n(.*?)```", readme, re.S)
        (sc / name).write_text(m.group(1))

    def run(cmd, **kw):
        return subprocess.run(cmd, cwd=sc, env=env, capture_output=True, text=True, **kw)

    results = []

    def case(name, ok, detail=""):
        results.append((name, ok, detail.strip().splitlines()[-1][:160] if detail.strip() else ""))

    r = run(["kairo", "hello.k", "-o", "hello"]); o = run(["./hello"]) if r.returncode == 0 else r
    case("1 kairo hello", r.returncode == 0 and "Hello from Kairo" in o.stdout, r.stderr or o.stderr)
    r = run(["kcc", "-x", "c", "h.c", "-o", "hc"]); o = run(["./hc"]) if r.returncode == 0 else r
    case("2a kcc C hello", r.returncode == 0 and "hello c" in o.stdout, r.stderr)
    r = run(["kcc", "h.cc", "-o", "hcc"]); o = run(["./hcc"]) if r.returncode == 0 else r
    case("2b kcc C++ hello", r.returncode == 0 and "hello c++" in o.stdout, r.stderr)
    r = run(["kcc", "main.cpp", "-std=c++23", "-o", "mixed"]); o = run(["./mixed"]) if r.returncode == 0 else r
    case("3 mixed packet.k + main.cpp", r.returncode == 0 and "[C++] total" in o.stdout, r.stderr)
    for t, magic in (("x86_64-windows-gnu", b"MZ"), ("aarch64-linux-musl", b"\x7fELF"),
                     ("wasm32-wasi", b"\0asm"), ("x86_64-unknown-freebsd", b"\x7fELF")):
        r = run(["kairo", "--target", t, "hello.k", "-o", f"x_{t}"])
        f = sc / f"x_{t}"
        case(f"4 cross link {t}", r.returncode == 0 and f.is_file() and f.read_bytes()[:4].startswith(magic), r.stderr)
    r1 = run(["kcc", "-c", "lib.c", "-o", "lib.o"]); r2 = run(["llvm-ar", "rcs", "libadd.a", "lib.o"])
    r3 = run(["llvm-ranlib", "libadd.a"]); r4 = run(["kcc", "m.c", "-L.", "-ladd", "-o", "sl"])
    o = run(["./sl"]) if r4.returncode == 0 else r4
    case("5 llvm-ar static lib", all(x.returncode == 0 for x in (r1, r2, r3, r4)) and o.stdout.strip() == "5",
         r1.stderr + r2.stderr + r3.stderr + r4.stderr)
    r = run(["kairo", "--target", "x86_64-apple-macosx", "hello.k", "-o", "ap"])
    names = "--sysroot" in r.stderr + r.stdout
    case("6 apple target (expect a refusal naming --sysroot)", r.returncode != 0 and names,
         f"exit {r.returncode}; names --sysroot: {names}; " + (r.stderr.strip().splitlines() or [""])[-1])
    if shutil.which("strace"):
        bad = []
        for label, cmd in (("kairo", ["kairo", "hello.k", "-o", "h1"]), ("kcc-c", ["kcc", "-x", "c", "h.c", "-o", "h2"]),
                           ("kcc-c++", ["kcc", "h.cc", "-o", "h3"])):
            run(["strace", "-f", "-e", "trace=execve", "-o", "st.txt"] + cmd)
            ex = [l for l in (sc / "st.txt").read_text().splitlines() if "execve(" in l]
            bad += [f"{label}: {l.split('execve(')[1][:60]}" for l in ex[1:]]
        case("7 strace: no child execs", not bad, "; ".join(bad))
    w = max(len(n) for n, _, _ in results)
    for n, ok, d in results:
        print(f"{n:<{w}}  {'PASS' if ok else 'FAIL'}  {d if not ok or n.startswith('6') else ''}")
    return 0 if all(ok for n, ok, _ in results if not n.startswith("6")) else 1


if __name__ == "__main__":
    sys.exit(main())
