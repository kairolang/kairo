#!/usr/bin/env python3
"""Before/after link verification for Scripts/trim_bsd_sysroot.py (stdlib only).

For each BSD target, runs the same battery against the curated root and its
trimmed copy and compares: exit status, sha256 of every linked output, DT_NEEDED
and undefined symbols (readelf/nm from the Kairo toolchain). Link-only: nothing
is executed. Also does a -fsyntax-only TU per header under the root's include
dirs and a `-lNAME` resolution test per library in the original.

    verify_bsd_trim.py [--bin DIR] [--jobs N] [targets...]

Writes build/sysgen/bsd-trim/verify/<target>.json and prints the comparison.
"""
import argparse
import concurrent.futures as cf
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ORIG_BASE = os.path.join(REPO, "build/x86_64-linux-gnu/release/sysroot")
TRIM_BASE = os.path.join(REPO, "build/sysgen/bsd-trim")
BIN = os.path.join(REPO, "build/x86_64-linux-musl/release/bin")
TARGETS = ["x86_64-unknown-freebsd", "aarch64-unknown-freebsd", "x86_64-unknown-netbsd"]

HELLO_K = 'import std::io\nfn main() -> i32 {\n  io::println("hi")\n  return 0\n}\n'
HELLO_C = '#include <stdio.h>\nint main(void){puts("hi");return 0;}\n'
HELLO_IOSTREAM = '#include <iostream>\nint main(){std::cout<<"hi\\n";}\n'
HELLO_THREAD = ('#include <thread>\n#include <iostream>\n'
                'int main(){std::thread t([]{std::cout<<"hi\\n";});t.join();}\n')
HELLO_FS = ('#include <filesystem>\n#include <iostream>\n'
            'int main(){std::cout<<std::filesystem::current_path().string()<<"\\n";}\n')
MATH_PTHREAD = ('#include <math.h>\n#include <pthread.h>\n#include <stdio.h>\n'
                'static void*f(void*a){return a;}\n'
                'int main(int c,char**v){pthread_t t;pthread_create(&t,0,f,0);'
                'pthread_join(t,0);printf("%f\\n",sin((double)c));return 0;}\n')
PORT_C = ('#include <zlib.h>\n#include <openssl/sha.h>\n#include <execinfo.h>\n'
          '#include <stdio.h>\n'
          'int main(void){unsigned char d[32],b[4]="abc";SHA256(b,3,d);'
          'void*bt[4];backtrace(bt,4);printf("%lu %d\\n",crc32(0,b,3),d[0]);return 0;}\n')


def run(cmd, cwd, stdin=None):
    p = subprocess.run(cmd, cwd=cwd, input=stdin, capture_output=True, text=True)
    return p.returncode, (p.stdout + p.stderr).strip()


def elf_facts(path):
    _, dyn = run(["readelf", "-d", path], None)
    needed = sorted(re.findall(r"\(NEEDED\)\s+Shared library: \[(.*?)\]", dyn))
    _, und = run([os.path.join(BIN, "llvm-nm"), "-u", path], None)
    undefined = sorted(l.split()[-1] for l in und.splitlines() if l.strip())
    with open(path, "rb") as f:
        sha = hashlib.sha256(f.read()).hexdigest()
    return {"sha": sha, "needed": needed, "undefined": undefined}


def battery(target, root, work, jobs, bindir):
    kcc = os.path.join(bindir, "kcc")
    kairo = os.path.join(bindir, "kairo")
    os.makedirs(work, exist_ok=True)
    # --sysroot is ignored when <toolchain>/sysroot/<target> exists, so prove which
    # root this battery really resolves to before trusting any of its results.
    _, jobsline = run([kcc, f"--target={target}", "--sysroot", root, "-x", "c", "-", "-o", "x", "-###"],
                      work, "int main(){}")
    want = os.path.realpath(root)
    got = {os.path.realpath(m) for m in re.findall(r"--sysroot=(\S+)", jobsline)}
    if got != {want}:
        raise SystemExit(f"{target}: toolchain {bindir} resolves sysroot {got}, expected {want}")
    srcs = {"h.k": HELLO_K, "h.c": HELLO_C, "iostream.cc": HELLO_IOSTREAM,
            "thread.cc": HELLO_THREAD, "fs.cc": HELLO_FS, "mp.c": MATH_PTHREAD,
            "port.c": PORT_C}
    for n, t in srcs.items():
        with open(os.path.join(work, n), "w") as f:
            f.write(t)
    base = [kcc, f"--target={target}", "--sysroot", root]
    pth = "-lthr" if "freebsd" in target else "-lpthread"
    link_libs = ["-lz", "-lssl", "-lcrypto", "-lexecinfo", "-lutil", "-lkvm", "-lrt"]
    tests = {
        "kairo-hello": [kairo, "h.k", "--target", target, "--sysroot", root, "-o", "kairo-hello"],
        "c-hello": base + ["h.c", "-o", "c-hello"],
        "c-hello-static": base + ["-static", "h.c", "-o", "c-hello-static"],
        "cxx-iostream": base + ["iostream.cc", "-o", "cxx-iostream"],
        "cxx-thread": base + ["thread.cc", "-o", "cxx-thread"],
        "cxx-filesystem": base + ["fs.cc", "-o", "cxx-filesystem"],
        "cxx-iostream-static": base + ["-static", "iostream.cc", "-o", "cxx-iostream-static"],
        "c-m-pthread": base + ["mp.c", "-lm", "-lpthread", "-o", "c-m-pthread"],
        "c-m-thr/pthread-native": base + ["mp.c", "-lm", pth, "-o", "c-m-native"],
        "c-port-libs": base + ["port.c"] + link_libs + [pth, "-lm", "-o", "c-port-libs"],
    }
    out = {}
    for name, cmd in tests.items():
        rc, msg = run(cmd, work)
        outf = cmd[cmd.index("-o") + 1]
        res = {"rc": rc}
        if rc == 0 and os.path.exists(os.path.join(work, outf)):
            res.update(elf_facts(os.path.join(work, outf)))
        else:
            res["err"] = msg[-300:]
        out[name] = res

    # per-library -lNAME resolution (static-only sysroots resolve .a)
    names = set()
    for d in ("usr/lib", "lib", "libcxx/lib"):
        p = os.path.join(root_orig(target), d)
        for n in os.listdir(p):
            m = re.match(r"lib(.+?)(_p)?\.(a|so)(\.[0-9.]+)?$", n)
            if m and not m.group(2):
                names.add(m.group(1))
    libs = {}

    def libtest(n):
        rc, msg = run(base + ["h.c", f"-l{n}", "-o", f"l_{n}".replace("+", "p")], work)
        return n, rc, msg[-160:]
    with cf.ThreadPoolExecutor(jobs) as ex:
        for n, rc, msg in ex.map(libtest, sorted(names)):
            libs[n] = {"rc": rc, "err": msg if rc else ""}
    out["-lNAME"] = libs

    # header TUs
    hdrs = {}
    jobs_l = []
    for inc in ("libcxx/include/c++/v1", "usr/include"):
        d = os.path.join(root_orig(target), inc)
        for dp, _, fns in os.walk(d):
            for fn in fns:
                rel = os.path.relpath(os.path.join(dp, fn), d)
                if os.path.splitext(fn)[1] in (".h", "") or inc.startswith("libcxx"):
                    cxx = inc.startswith("libcxx") or rel.startswith(("c++/", "g++/")) \
                        or fn.endswith((".hpp", ".hh"))
                    jobs_l.append((inc + ":" + rel, rel, cxx))

    def hdrtest(j):
        key, rel, cxx = j
        src = f"#include <{rel}>\n"
        rc, msg = run(base + ["-fsyntax-only", "-x", "c++" if cxx else "c", "-"], work, src)
        return key, rc, msg[-160:]
    with cf.ThreadPoolExecutor(jobs) as ex:
        for key, rc, msg in ex.map(hdrtest, jobs_l):
            hdrs[key] = {"rc": rc, "err": msg if rc else ""}
    out["headers"] = hdrs
    return out


def setup_toolchain(tc):
    """A second toolchain prefix whose sysroot/ holds the trimmed roots. Binaries are
    hard links (a symlinked executable resolves back to the original prefix)."""
    import shutil
    shutil.rmtree(tc, ignore_errors=True)
    os.makedirs(os.path.join(tc, "bin"))
    os.makedirs(os.path.join(tc, "sysroot"))
    src = os.path.dirname(BIN)
    for n in os.listdir(BIN):
        p = os.path.join(BIN, n)
        if os.path.islink(p):
            os.symlink(os.readlink(p), os.path.join(tc, "bin", n))
        else:
            os.link(p, os.path.join(tc, "bin", n))
    for d in os.listdir(src):
        if d not in ("bin", "sysroot") and not os.path.exists(os.path.join(tc, d)):
            os.symlink(os.path.join(src, d), os.path.join(tc, d))
    for t in TARGETS:
        os.symlink(os.path.join(TRIM_BASE, t), os.path.join(tc, "sysroot", t))
    return os.path.join(tc, "bin")


def root_orig(target):
    return os.path.join(ORIG_BASE, target)


def removed_set(target):
    out = set()
    with open(os.path.join(TRIM_BASE, target + ".manifest.tsv")) as f:
        for line in f:
            c, _, rel, _ = (line.rstrip("\n").split("\t") + ["", "", "", ""])[:4]
            if c and not c.startswith("#") and c != "restored":
                out.add(rel)
    return out


def compare(target, a, b, trim_root):
    gone = removed_set(target)
    lines = []
    bad = 0
    lines.append(f"### {target}")
    lines.append("| test | original | trimmed | identical output |")
    lines.append("|---|---|---|---|")
    for name, ra in a.items():
        if name in ("-lNAME", "headers"):
            continue
        rb = b[name]
        same = ra["rc"] == rb["rc"] and (ra["rc"] != 0 or (
            ra["sha"] == rb["sha"] and ra["needed"] == rb["needed"]
            and ra["undefined"] == rb["undefined"]))
        status = lambda r: "ok" if r["rc"] == 0 else "FAIL"
        extra = ""
        if ra["rc"] == 0:
            extra = f"sha {'=' if ra['sha'] == rb.get('sha') else '!='}, " \
                    f"NEEDED {'=' if ra['needed'] == rb.get('needed') else '!='}, " \
                    f"undef {'=' if ra['undefined'] == rb.get('undefined') else '!='}"
        lines.append(f"| {name} | {status(ra)} | {status(rb)} | {'YES' if same else 'NO'} {extra} |")
        bad += 0 if same else 1
    for key, label in (("-lNAME", "-l<lib> resolution"), ("headers", "header TU")):
        ra, rb = a[key], b[key]
        both = [k for k in ra if ra[k]["rc"] and rb.get(k, {"rc": 1})["rc"]]
        # a header deleted on purpose (duplicate/toolchain rule) is accounted for by the
        # manifest, not counted as a regression
        def deleted(k):
            return key == "headers" and k.replace(":", "/", 1) in gone
        only_trim = [k for k in ra if (not ra[k]["rc"]) and rb.get(k, {"rc": 1})["rc"]
                     and not deleted(k)]
        n_deleted = sum(1 for k in ra if (not ra[k]["rc"]) and rb.get(k, {"rc": 1})["rc"]
                        and deleted(k))
        only_orig = [k for k in ra if ra[k]["rc"] and not rb.get(k, {"rc": 1})["rc"]]
        ok = [k for k in ra if not ra[k]["rc"] and not rb.get(k, {"rc": 1})["rc"]]
        lines.append(f"| {label} | {len(ra)} items | | ok both {len(ok)}, fail both (pre-existing) "
                     f"{len(both)}, only-trimmed {len(only_trim)}"
                     f"{f', deliberately deleted {n_deleted}' if key == 'headers' else ''} |")
        a[key + "_only_trim"] = only_trim
        if key == "headers":
            bad += len(only_trim)
        lines.append("")
    return "\n".join(lines), bad


def main():
    global BIN
    ap = argparse.ArgumentParser()
    ap.add_argument("targets", nargs="*", default=TARGETS)
    ap.add_argument("--bin", default=BIN)
    ap.add_argument("--jobs", type=int, default=16)
    ap.add_argument("--keep", action="store_true")
    a = ap.parse_args()
    BIN = a.bin
    outdir = os.path.join(TRIM_BASE, "verify")
    os.makedirs(outdir, exist_ok=True)
    tcbin = setup_toolchain(os.path.join(TRIM_BASE, "tc"))
    rc_all = 0
    for t in a.targets:
        with tempfile.TemporaryDirectory(prefix="bsdtrim-", dir=outdir) as tmp:
            ra = battery(t, root_orig(t), os.path.join(tmp, "orig"), a.jobs, BIN)
            rb = battery(t, os.path.join(TRIM_BASE, t), os.path.join(tmp, "trim"), a.jobs, tcbin)
        with open(os.path.join(outdir, t + ".json"), "w") as f:
            json.dump({"orig": ra, "trim": rb}, f, indent=1)
        text, bad = compare(t, ra, rb, os.path.join(TRIM_BASE, t))
        # list -l regressions explicitly: these are removed libraries by design
        lost = sorted(k for k in ra["-lNAME"] if ra["-lNAME"][k]["rc"] == 0
                      and rb["-lNAME"][k]["rc"] != 0)
        text += f"\n-l<lib> resolvable in original, not in trimmed: {' '.join(lost) or '(none)'}\n"
        hl = sorted(k for k in ra["headers"] if ra["headers"][k]["rc"] == 0
                    and rb["headers"][k]["rc"] != 0 and k.replace(":", "/", 1) not in removed_set(t))
        text += f"headers OK in original, failing in trimmed (excluding deliberate deletions): {len(hl)} {hl[:10]}\n"
        print(text)
        with open(os.path.join(outdir, t + ".md"), "w") as f:
            f.write(text)
        rc_all |= 1 if bad else 0
    return rc_all


if __name__ == "__main__":
    sys.exit(main())
