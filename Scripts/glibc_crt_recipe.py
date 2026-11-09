#!/usr/bin/env python3
"""glibc start files and libc_nonshared.a from source: the tables ksys compiles them from.

Maintainer tool, never shipped. The idea (compile crt1.o / Scrt1.o / libc_nonshared.a from a
shipped glibc subset, with version gates at 2.33 and 2.34) follows Zig's src/libs/glibc.zig; no
code or data of it is used. Unlike Zig's hand-kept lists, the compiles here are glibc's OWN: per
era and arch, glibc's configure and make run offline with clang as CC (as for install-headers,
Scripts/glibc_headers.py) and build exactly

    csu/crt1.o csu/Scrt1.o csu/crti.o csu/crtn.o  and every subdir's $(static-only-routines) .oS

and every compile and `-r` link make prints is captured, with its -MD dependency list. The
dependency lists are the shipped source subset (glibc/src/<era>/) and the generated headers
(config.h, libc-modules.h, abi-tag.h, ...: glibc's own configure + make output) go beside the
table (glibc/crt/<era>/<arch>/gen/).

Eras: a target release picks the newest era not newer than it.
    2.32  start.S passes __libc_csu_init/fini; libc_nonshared.a has elf-init and the stat
          family (stat -> __xstat); targets 2.17 .. 2.32
    2.33  stat is exported by libc.so; still the init/fini start files; target 2.33
    2.42  __libc_start_main@GLIBC_2.34, no elf-init; targets 2.34 .. newest

Output (FORMAT.md "glibc/crt"):
    glibc/src/<era>/...                  the files the compiles read
    glibc/crt/<era>/<arch>.toml          compiles, links, archive (TOML subset)
    glibc/crt/<era>/<arch>/gen/...       generated headers

    python3 Scripts/glibc_crt_recipe.py --git build/sysgen/glibc --linux build/sysgen/linux \
        --work build/sysgen/z4/crt --out DIR [--arches ...] [--eras ...]

The compile commands reach the table with their absolute paths rewritten: the era source dir
-> {src}, the build dir -> {gen}, the kernel headers -> {uapi}; `-nostdinc -isystem <clang resource>/include`
becomes -nostdlibinc (the same headers, wherever the compiler is); -g and the -MD/-MF/-MT
bookkeeping are dropped (nothing else is).
"""
import argparse
import os
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import io
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ERAS = {"2.32": ("2.17", "2.32"), "2.33": ("2.33", "2.33"), "2.42": ("2.34", None)}
# sysroot arch -> configure --host, clang --target, kernel ARCH, first release
ARCHES = {
    "x86_64": ("x86_64-linux-gnu", "x86_64-linux-gnu", "x86", "2.17"),
    "x32": ("x86_64-linux-gnux32", "x86_64-linux-gnux32", "x86", "2.17"),
    "i686": ("i686-linux-gnu", "i686-linux-gnu", "x86", "2.17"),
    "aarch64": ("aarch64-linux-gnu", "aarch64-linux-gnu", "arm64", "2.17"),
    "aarch64_be": ("aarch64_be-linux-gnu", "aarch64_be-linux-gnu", "arm64", "2.17"),
    "armv7": ("arm-linux-gnueabihf", "armv7a-linux-gnueabihf", "arm", "2.17"),
    "riscv32": ("riscv32-linux-gnu", "riscv32-linux-gnu", "riscv", "2.33"),
    "riscv64": ("riscv64-linux-gnu", "riscv64-linux-gnu", "riscv", "2.27"),
    "powerpc": ("powerpc-linux-gnu", "powerpc-linux-gnu", "powerpc", "2.17"),
    "powerpc64": ("powerpc64-linux-gnu", "powerpc64-linux-gnu", "powerpc", "2.17"),
    "powerpc64le": ("powerpc64le-linux-gnu", "powerpc64le-linux-gnu", "powerpc", "2.19"),
    "s390x": ("s390x-linux-gnu", "s390x-linux-gnu", "s390", "2.17"),
    "mips": ("mips-linux-gnu", "mips-linux-gnu", "mips", "2.17"),
    "mipsel": ("mipsel-linux-gnu", "mipsel-linux-gnu", "mips", "2.17"),
    "mips64": ("mips64-linux-gnuabi64", "mips64-linux-gnuabi64", "mips", "2.17"),
    "mips64el": ("mips64el-linux-gnuabi64", "mips64el-linux-gnuabi64", "mips", "2.17"),
    "loongarch64": ("loongarch64-linux-gnu", "loongarch64-linux-gnu", "loongarch", "2.36"),
    "sparc64": ("sparc64-linux-gnu", "sparc64-linux-gnu", "sparc", "2.17"),
}
# x32: glibc's x32 syscall macros (sysdeps/unix/sysv/linux/x86_64/x32/sysdep.h, ARGIFY) are
# rejected by clang ("variable has incomplete type typeof(...)") in every era: no start files,
# so no x32 root (its abilists and headers ship). P680.
NO_CRT = {"x32"}
CRT = ["csu/crt1.o", "csu/Scrt1.o", "csu/crti.o", "csu/crtn.o"]
# Configure checks that need a working link or a GCC: what they would find for a GNU toolchain.
CACHE = ["libc_cv_compiler_ok=yes", "libc_cv_compiler_ok_on_s390x=yes", "libc_cv_gcc_builtin_redirection=yes", "libc_cv_pde_load_address=0x400000",
         "libc_cv_mlong_double_128=yes", "libc_cv_mlong_double_128ibm=yes", "libc_cv_no_gnu_attr_ok=yes"]


def vkey(v):
    return tuple(int(x) for x in v.split("."))


def log(m):
    print(f"[glibc-crt] {m}", file=sys.stderr, flush=True)


def run(cmd, logf, **kw):
    with open(logf, "w") as f:
        return subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT, **kw).returncode


# GCC options glibc's makefiles pass that clang rejects, and what stands in for each (none of
# them changes the code of the files the tables compile). Applied by the wrapper make runs and
# again to the commands written into the tables, so a table holds what kcc accepts.
DROP = {"-mno-gnu-attribute",      # ppc64le: suppress .gnu.attributes; clang emits none anyway
        "-fcall-used-g6",          # sparc: g6 call-clobbered; clang never allocates g6
        "-Wa,-execstack"}          # mips: the default; clang's assembler has no such option
DROP_PREFIX = ("-Wa,-mtune=",)     # i386: an assembler tuning hint
WA_TO_DRIVER = {"-Wa,-mno-relax": "-mno-relax"}   # riscv: the driver option clang has
# -mabi values clang's driver takes but kcc hands to LLVM as an ABI name it rejects (P681);
# each is the default of the triple the tables are compiled for, so dropping it changes
# nothing (mips o32, mips64 n64), or touches only long double, which no start file or
# libc_nonshared member uses (ppc64le IEEE binary128 long double).
DROP_MABI = {"-mabi=32", "-mabi=64", "-mabi=ieeelongdouble"}


def clang_args(argv: list) -> list:
    """argv (without the program) as clang takes it."""
    out, i = [], 0
    s390 = any(a.startswith("--target=s390") for a in argv)
    while i < len(argv):
        a = argv[i]
        if a in DROP or a in DROP_MABI or a.startswith(DROP_PREFIX):
            pass
        elif a in WA_TO_DRIVER:
            out.append(WA_TO_DRIVER[a])
        elif a == "-G" and i + 1 < len(argv):      # powerpc32: small-data threshold (GCC only)
            i += 1
        elif re.fullmatch(r"-G\d+", a):
            pass
        elif a == "-mlong-double-128" and s390:    # s390x: clang's long double is 128-bit already
            pass
        else:
            out.append(a)
        i += 1
    return out


def clang_wrapper(work: Path) -> Path:
    """The CC glibc's configure and make run: clang with clang_args(); a link (no -c/-S/-E) with
    lld, since no cross binutils are installed; and glibc's gen-as-const compiles C with -S and
    reads the asm text, which clang's integrated assembler would reject (marker strings in
    inline asm), so a -S compile skips it."""
    w = work / "clangw"
    w.write_text(f"""#!/usr/bin/env python3
import os, sys
sys.path.insert(0, {str(ROOT / "Scripts")!r})
from glibc_crt_recipe import clang_args
a = clang_args(sys.argv[1:])
if "-S" in a:
    a = ["-fno-integrated-as"] + a
elif not any(x in ("-c", "-E", "-M", "-MM") for x in a):
    a = ["-fuse-ld=lld"] + a
os.execvp("clang", ["clang"] + a)
""")
    w.chmod(0o755)
    return w


# Source changes clang needs, applied to every era's tree before make (so the tables and the
# shipped glibc/src carry them). Each keeps the code GCC would emit.
PATCHES = [
    # mips: clang has no "v" (v0/v1) constraint; pin the result to $3 (v1) instead
    ("sysdeps/mips/nptl/tls.h", "({ void *__result;", "({ register void *__result __asm__ (\"$3\"); /* Kairo: clang */"),
    ("sysdeps/mips/nptl/tls.h", '"=v" (__result)', '"=r" (__result)'),
]


def patch(src: Path) -> None:
    for rel, old, new in PATCHES:
        f = src / rel
        t = f.read_text()
        if new in t:
            continue
        if old not in t:
            raise RuntimeError(f"{f}: patch target {old!r} not found")
        f.write_text(t.replace(old, new))


def source(git: Path, tag: str, work: Path) -> Path:
    s = work / "src" / f"glibc-{tag}"
    if not (s / "configure").is_file():
        shutil.rmtree(s, ignore_errors=True)
        s.parent.mkdir(parents=True, exist_ok=True)
        data = subprocess.run(["git", "-C", str(git), "archive", f"--prefix=glibc-{tag}/", f"glibc-{tag}"],
                              capture_output=True, check=True).stdout
        with tarfile.open(fileobj=io.BytesIO(data)) as tf:
            tf.extractall(s.parent, filter="tar")
    patch(s)        # idempotent: an extracted tree is patched once
    return s


def uapi(linux: Path, karch: str, work: Path) -> Path:
    out = work / "uapi" / karch
    if not (out / "include/linux/version.h").is_file():
        if run(["make", "-s", "-C", str(linux), f"O={work}/kbuild-{karch}", f"ARCH={karch}", "headers_install",
                f"INSTALL_HDR_PATH={out}"], work / f"uapi-{karch}.log"):
            raise RuntimeError(f"headers_install ARCH={karch} failed")
        shutil.rmtree(work / f"kbuild-{karch}", ignore_errors=True)
    return out / "include"


def configure(src: Path, b: Path, arch: str, inc: Path, cc: Path) -> None:
    host, tgt, _, _ = ARCHES[arch]
    if (b / "config.make").is_file():
        return
    shutil.rmtree(b, ignore_errors=True)
    b.mkdir(parents=True)
    cmd = [str(src / "configure"), f"--host={host}", "--build=x86_64-pc-linux-gnu", "--prefix=/usr",
           f"CC={cc} --target={tgt}", "CXX=no", "LD=ld.lld", "AR=llvm-ar", "NM=llvm-nm", "OBJCOPY=llvm-objcopy",
           "OBJDUMP=llvm-objdump", "READELF=llvm-readelf", "RANLIB=llvm-ranlib", "STRIP=llvm-strip",
           f"AS=clang --target={tgt} -c", *CACHE, f"--with-headers={inc}", "--disable-werror",
           "--enable-kernel=3.2"]
    if run(cmd, b / "cfg.log", cwd=b):
        raise RuntimeError(f"configure {arch} failed, see {b}/cfg.log")


def make_eval(src: Path, b: Path, var: str, sub: str = "") -> list:
    d = src / sub if sub else src
    extra = [f"subdir={sub}"] if sub else []
    r = subprocess.run(["make", "-r", "-s", "--no-print-directory", "-C", str(d), f"objdir={b}", *extra,
                        "--eval", f"zz4: ; @echo ZZ4 $({var})", "zz4"], capture_output=True, text=True)
    for l in r.stdout.splitlines():
        if l.startswith("ZZ4"):
            return l.split()[1:]
    return []


def make_targets(src: Path, b: Path, sub: str, targets: list, logf: Path) -> list:
    """make the targets in subdir `sub`; a generated header glibc's gen-as-const cannot make
    with clang (rtld-offsets.h: __builtin_va_arg_pack) is faked empty when no target needs it
    (checked against the dependency lists afterwards). Returns the faked paths."""
    faked = []
    for _ in range(12):
        rc = run(["make", "-r", "-C", str(src / sub), f"objdir={b}", f"subdir={sub}", "cross-compiling=yes",
                  *[str(b / t) for t in targets]], logf)
        if rc == 0:
            return faked
        text = logf.read_text(errors="replace")
        m = re.search(r"\*\*\* \[[^\]]*?: (\S+?\.(?:h|bin))\] Error", text)
        if not m:
            raise RuntimeError(f"make {sub} failed, see {logf}")
        p = Path(m.group(1))
        p.write_text("")
        Path(str(p) + ".d").write_text("")
        faked.append(p)
    raise RuntimeError(f"make {sub}: too many faked headers, see {logf}")


def parse_deps(dfile: Path, src_sub: Path, b: Path) -> list:
    text = dfile.read_text().replace("$(common-objpfx)", str(b) + "/")
    first = text.replace("\\\n", " ").splitlines()[0]   # the object's own rule; -MP phonies follow
    text = first.split(":", 1)[1]
    out = []
    for tok in text.split():
        p = Path(tok) if tok.startswith("/") else (src_sub / tok)
        out.append(Path(os.path.normpath(p)))
    return out


def rewrite(args: list, src: Path, sub: str, b: Path, inc: Path, res: str) -> list:
    """Absolute and subdir-relative paths -> placeholders; -g and -M* dropped."""
    out, skip = [], False
    s, bb, ii = str(src), str(b), str(inc)

    def path(p):
        q = p if p.startswith("/") else os.path.normpath(os.path.join(s, sub, p))
        if q.startswith(bb):
            return "{gen}" + q[len(bb):]
        if q.startswith(s):
            return "{src}" + q[len(s):]
        if q.startswith(ii):
            return "{uapi}" + q[len(ii):]
        if q.startswith(res):
            return "{resource}" + q[len(res):]
        return p
    it = iter(args)
    for a in it:
        if skip:
            skip = False
            continue
        if a in ("-MF", "-MT", "-MQ"):
            skip = True
            continue
        if a in ("-MD", "-MP", "-g") or a.startswith("-g"):
            continue
        if a == "-nostdinc":
            # the compiler's own headers stay (stddef.h, stdarg.h): -nostdlibinc drops only the
            # system dirs, so the table names no resource dir
            out.append("-nostdlibinc")
            continue
        if a in ("-I", "-isystem", "-include", "-o"):
            nxt = next(it)
            if a == "-isystem" and os.path.normpath(nxt).startswith(res):
                continue
            out += [a, path(nxt).replace("{gen}", "{out}", 1) if a == "-o" else path(nxt)]
            continue
        if a.startswith("-I") and len(a) > 2:
            out.append("-I" + path(a[2:]))
            continue
        if a.endswith((".c", ".S", ".s")) and not a.startswith("-"):
            out.append(path(a))
            continue
        out.append(a)
    return out


def build(git, linux, work, era, arch, cc, res):
    src = source(git, era, work)
    inc = uapi(linux, ARCHES[arch][2], work)
    b = work / "b" / era / arch
    configure(src, b, arch, inc, cc)
    # every object is recompiled, so make prints every compile
    for pat in ("*.o", "*.os", "*.oS"):
        for o in b.rglob(pat):
            o.unlink()
    for lg in b.glob("z4-*.log"):
        lg.unlink()
    faked = make_targets(src, b, "csu", CRT, b / "z4-csu+crt.log")
    ns = []
    for sub in make_eval(src, b, "subdirs"):
        for r in make_eval(src, b, "static-only-routines", sub):
            ns.append((sub, r))
    by_sub = {}
    for sub, r in ns:
        by_sub.setdefault(sub, []).append(f"{sub}/{r}.oS")
    for sub, ts in by_sub.items():
        faked += make_targets(src, b, sub, ts, b / f"z4-{sub}.log")
    # Compiles and links as make printed them.
    compiles, links = {}, {}
    for logf in sorted(b.glob("z4-*.log")):
        sub = logf.stem[3:].split("+")[0]
        for line in logf.read_text(errors="replace").splitlines():
            if not line.startswith(str(cc)):
                continue
            try:
                argv = shlex.split(line)
            except ValueError:
                continue                    # a continued shell line, not a compile
            if "-o" not in argv:
                continue
            o = argv[argv.index("-o") + 1]
            if not o.startswith(str(b)):
                continue
            rel = o[len(str(b)) + 1:]
            if "-r" in argv:
                links[rel] = [x[len(str(b)) + 1:] for x in argv if x.startswith(str(b)) and x != o]
            elif "-c" in argv:
                compiles[rel] = (sub, clang_args(argv[1:]))
    # only what the start files and the archive are made of (glibc's before-compile probes,
    # no_ldbl_gnu_attribute.o and the like, are not)
    need = set(CRT) | {f"{s_}/{r}.oS" for s_, r in ns} | {x for ins in links.values() for x in ins}
    compiles = {k: v for k, v in compiles.items() if k in need}
    missing = sorted(need - set(compiles) - set(links))
    if missing:
        raise RuntimeError(f"{arch} {era}: no compile captured for {missing}")
    files, gen = set(), set()
    for rel, (sub, argv) in compiles.items():
        d = b / (rel + ".d")
        if not d.is_file():
            d = b / (rel + ".dt")     # .oS deps are renamed only by the stamp rule
        for p in parse_deps(d, src / sub, b):
            if str(p).startswith(str(src)):
                files.add(p.relative_to(src))
            elif str(p).startswith(str(b)):
                if p in faked:
                    raise RuntimeError(f"{arch} {era}: {rel} needs the faked {p}")
                gen.add(p.relative_to(b))
    return dict(era=era, arch=arch, src=src, b=b, inc=inc, res=res, compiles=compiles, links=links,
                members=[f"{s}/{r}.oS" for s, r in ns], files=files, gen=gen, faked=faked)


def q(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def table(r) -> str:
    era, arch = r["era"], r["arch"]
    lo, hi = ERAS[era]
    first = ARCHES[arch][3]
    lines = [f"# generated by Scripts/glibc_crt_recipe.py; do not edit. Format: FORMAT.md (glibc/crt).",
             f"# glibc-{era} configure + make, clang --target={ARCHES[arch][1]}: the compiles make ran for",
             "# csu/{crt1,Scrt1,crti,crtn}.o and the static-only routines (libc_nonshared.a).",
             f'era      = "{era}"',
             f'releases = "{max(lo, first, key=vkey)}-{hi or "newest"}"',
             f'target   = "{ARCHES[arch][1]}"',
             "objects  = [" + ", ".join(q(o) for o in sorted(r["compiles"])) + "]",
             "crt      = [" + ", ".join(q(Path(c).name) for c in CRT) + "]",
             "nonshared = [" + ", ".join(q(m) for m in r["members"]) + "]"]
    for i, (rel, (sub, argv)) in enumerate(sorted(r["compiles"].items())):
        args = rewrite(argv, r["src"], sub, r["b"], r["inc"], r["res"])
        # argv[0] was `--target=...` (the wrapper is the program): keep it as the table's target
        args = [a for a in args if not a.startswith("--target=")]
        lines += ["", f"[compile.o{i}]", f"out  = {q(rel)}", "args = ["]
        lines += [f"    {q(a)}," for a in args]
        lines += ["]"]
    for i, (rel, ins) in enumerate(sorted(r["links"].items())):
        lines += ["", f"[link.l{i}]", f"out    = {q(rel)}", "inputs = [" + ", ".join(q(x) for x in ins) + "]"]
    return "\n".join(lines) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--git", type=Path, required=True)
    ap.add_argument("--linux", type=Path, required=True)
    ap.add_argument("--work", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--arches", nargs="*", default=[x for x in ARCHES if x not in NO_CRT])
    ap.add_argument("--eras", nargs="*", default=list(ERAS))
    ap.add_argument("-j", type=int, default=6)
    a = ap.parse_args()
    a.work.mkdir(parents=True, exist_ok=True)
    cc = clang_wrapper(a.work.resolve())
    res = subprocess.run(["clang", "-print-resource-dir"], capture_output=True, text=True, check=True).stdout.strip()
    jobs = []
    for era in a.eras:
        source(a.git, era, a.work.resolve())
        for arch in a.arches:
            first = ARCHES[arch][3]
            hi = ERAS[era][1]
            if hi and vkey(first) > vkey(hi):
                continue
            jobs.append((era, arch))
    for k in sorted({ARCHES[x][2] for _, x in jobs}):
        uapi(a.linux, k, a.work.resolve())
    results, fails = [], []
    with ThreadPoolExecutor(a.j) as ex:
        futs = {ex.submit(build, a.git, a.linux, a.work.resolve(), e, x, cc, res): (e, x) for e, x in jobs}
        for f, (e, x) in futs.items():
            try:
                results.append(f.result())
                log(f"{e} {x}: {len(f.result()['compiles'])} compiles, {len(f.result()['members'])} nonshared")
            except Exception as ex_:
                fails.append(f"{e} {x}: {ex_}")
                log(f"FAIL {e} {x}: {ex_}")
    out = a.out
    for r in results:
        era, arch = r["era"], r["arch"]
        t = out / "crt" / era
        t.mkdir(parents=True, exist_ok=True)
        (t / f"{arch}.toml").write_text(table(r))
        g = t / arch / "gen"
        shutil.rmtree(g, ignore_errors=True)
        for rel in sorted(r["gen"]):
            (g / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(r["b"] / rel, g / rel)
        for rel in sorted(r["files"]):
            d = out / "src" / era / rel
            d.parent.mkdir(parents=True, exist_ok=True)
            if not d.exists():
                shutil.copyfile(r["src"] / rel, d)
    for f in fails:
        print("FAIL", f)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
