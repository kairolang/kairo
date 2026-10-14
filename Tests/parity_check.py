#!/usr/bin/env python3
"""One parity case: kairo on the .k, clang on the .cpp beside it, same verdict.

The .cpp is the ORACLE (Tests/Sema/RedeclMerge/README.md, OVERLOAD.md: kairo's
behaviour here is 1:1 with C++). A divergence is a kairo bug unless it is
listed in kairo-only/README as a deliberate divergence -- in which case the
case does not belong in parity/ at all.

Only the VERDICT is compared, accept vs reject, not the message: the two
compilers have no reason to word a diagnostic the same way, and pinning kairo's
text to clang's would be a test of translation rather than of behaviour. What
rule each side applied is printed on divergence so a human can judge it.

Usage: parity_check.py <kairo> <clang> <file.k>
       <kairo> may carry flags as one shell-quoted word ('kairo --sysroot=..'):
       lit passes the C++ header roots that way.
Exit:  0 = same verdict, 1 = diverged, 2 = harness problem (missing oracle).
"""
import os
import re
import shlex
import subprocess
import sys

TIMEOUT = 120


def verdict(argv):
    """(accept|reject, combined output). A crash is NOT a reject."""
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        return "timeout", "timed out after %ds" % TIMEOUT
    out = (p.stdout or "") + (p.stderr or "")
    # A signal (negative returncode) means it died, which is neither an accept
    # nor a reject -- surfacing it as "reject" would let a crash masquerade as
    # correct behaviour on every reject case in the corpus.
    if p.returncode < 0:
        return "crash(signal %d)" % -p.returncode, out
    return ("accept" if p.returncode == 0 else "reject"), out


def _read_manifest(path):
    """SYSROOT.toml's sysroot / include_dirs / cc_defines. tomllib where the
    interpreter has it (3.11+); otherwise the three keys by hand -- kbld
    writes them as one-line scalars and one-line string arrays, nothing else.
    """
    try:
        import tomllib
        with open(path, "rb") as f:
            return tomllib.load(f)
    except ImportError:
        pass
    out = {}
    for line in open(path, encoding="utf-8"):
        line = line.split("#", 1)[0].strip()
        if "=" not in line:
            continue
        key, val = (x.strip() for x in line.split("=", 1))
        if val.startswith("["):
            out[key] = re.findall(r'"([^"]*)"', val)
        elif val.startswith('"'):
            out[key] = val.strip('"')
    return out


def sysroot_header_roots(sysroot):
    """(root, [include dirs]) for --sysroot, resolved the way kairo resolves
    the same flag (CompilerInstance::_sysroot_header_roots), so the oracle
    parses the headers kairo parsed:

      SYSROOT.toml  its include_dirs under <sysroot>/<manifest sysroot>
      Apple SDK     <sdk>/usr/include/c++/v1, <sdk>/usr/include
      otherwise     <sysroot>/include/c++/v1, <sysroot>/include (the bare
                    prefix layout ClangBackend keeps when nothing declares)
    Also the manifest's cc_defines, as -D flags.
    """
    manifest = os.path.join(sysroot, "SYSROOT.toml")
    if os.path.isfile(manifest):
        m = _read_manifest(manifest)
        root = sysroot
        if m.get("sysroot") and m["sysroot"] != ".":
            root = os.path.join(sysroot, m["sysroot"])
        dirs = [os.path.join(root, d) for d in m.get("include_dirs", [])]
        return root, dirs, list(m.get("cc_defines", []))
    if os.path.isfile(os.path.join(sysroot, "SDKSettings.json")):
        return sysroot, [os.path.join(sysroot, "usr", "include", "c++", "v1"),
                         os.path.join(sysroot, "usr", "include")], []
    return sysroot, [os.path.join(sysroot, "include", "c++", "v1"),
                     os.path.join(sysroot, "include")], []


def oracle_argv(clang, kairo_argv, cpp):
    """clang on the .cpp, seeing the SAME headers kairo's ffi imports see.

    Kairo's ClangBackend never discovers headers: it searches exactly the
    roots --sysroot resolves to (sysroot_header_roots) plus
    <resource-dir>/include, under -std=c++26. A bare `clang -fsyntax-only`
    does discover them, and on a GCC host that means libstdc++ -- so the
    oracle was judging a different standard library than the one kairo
    parsed, and a verdict could agree or diverge for reasons neither compiler
    controls. Mirror the roots from kairo's own flags; without them, fall
    back to asking for libc++ and let clang find it.
    """
    sysroot = resource = None
    for a in kairo_argv:
        if a.startswith("--sysroot="):
            sysroot = a.split("=", 1)[1]
        elif a.startswith("--resource-dir="):
            resource = a.split("=", 1)[1]
    argv = [clang, "-fsyntax-only", "-std=c++26", "-x", "c++"]
    if sysroot:
        root, dirs, defines = sysroot_header_roots(sysroot)
        cxx_dirs = [d for d in dirs if "/c++/" in d]
        c_dirs   = [d for d in dirs if "/c++/" not in d]
        argv += ["-nostdinc++", "-nostdlibinc", "-isysroot", root]
        for d in cxx_dirs:
            argv += ["-isystem", d]
        if resource:
            argv += ["-resource-dir", resource,
                     "-isystem", os.path.join(resource, "include")]
        for d in c_dirs:
            argv += ["-isystem", d]
        argv += ["-D" + d for d in defines]
    else:
        argv += ["-stdlib=libc++"]
    return argv + [cpp]


def main():
    if len(sys.argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    kairo, clang, kfile = sys.argv[1:4]

    cpp = kfile[:-2] + ".cpp" if kfile.endswith(".k") else kfile + ".cpp"
    if not os.path.isfile(cpp):
        print("NO-ORACLE: %s has no .cpp beside it.\n"
              "  Every case under parity/ is defined by its oracle. If C++ has\n"
              "  no analog for this construct it belongs in kairo-only/, with a\n"
              "  file-level comment saying why." % os.path.basename(kfile),
              file=sys.stderr)
        return 2

    kairo_argv = shlex.split(kairo)
    kv, kout = verdict(kairo_argv + [kfile, "--type-check-only"])
    cv, cout = verdict(oracle_argv(clang, kairo_argv, cpp))

    if kv == cv:
        print("ok  %s  (both %s)" % (os.path.basename(kfile), kv))
        return 0

    print("PARITY DIVERGENCE: %s" % kfile, file=sys.stderr)
    print("  kairo: %-8s clang: %s" % (kv, cv), file=sys.stderr)
    print("  --- kairo ---", file=sys.stderr)
    print(kout.rstrip() or "    (silent)", file=sys.stderr)
    print("  --- clang (oracle) ---", file=sys.stderr)
    print(cout.rstrip() or "    (silent)", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
