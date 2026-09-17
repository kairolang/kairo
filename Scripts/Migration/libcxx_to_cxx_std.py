#!/usr/bin/env python3
# libcxx::X -> cxx::std::X in Kairo source.
#
# `libcxx` is a Stage 0 bootstrap alias (`namespace libcxx = ::std;` in
# Lib/bootstrap/lib-helix/core/include/config/config.hh) with nothing behind it
# in Stage 1 resolution. Stage 1 reaches C++'s std through the `cxx` overlay,
# so `cxx::std::X` is the target spelling. See Compiler/Sema/IMPORTS.md 5.
#
# NOT purely textual, which is why this reports by default and only writes with
# --apply:
#
#   * `cxx` binds ONLY in a TU with an ffi import, and `cxx::std::X` only
#     resolves if X's header is in that TU's ffi closure. The rename is the
#     easy half; adding the right `ffi "c++" import` per file is the real work
#     and this script will not guess it. It tells you, per file, which headers
#     the symbols need and which are already imported.
#   * inline "c++" blocks hold real C++, where `cxx::std` is not a thing. Those
#     sites are reported as MANUAL and never rewritten. (inline "c++" is
#     unsupported from Stage 1 onward anyway, so they are going regardless.)
#   * Compiler/Native/*.hh and Lib/bootstrap are C++ by design. Skipped.
#
# Usage:
#   python3 Scripts/Migration/libcxx_to_cxx_std.py Compiler            # report
#   python3 Scripts/Migration/libcxx_to_cxx_std.py Compiler --apply    # rewrite
#   python3 Scripts/Migration/libcxx_to_cxx_std.py Compiler --apply --only Lexer
import re, sys, pathlib

SYM = re.compile(r'\blibcxx::([A-Za-z_]\w*)')
FFI = re.compile(r'ffi\s+"c\+\+"\s+import\s+"([^"]+)"')

# symbol -> the header that declares it. Anything not here is reported UNKNOWN
# rather than guessed: a wrong header is a link error three days later.
HEADER = {}
def _h(header, *names):
    for n in names: HEADER[n] = header

_h("<algorithm>",          "min", "max", "sort")
_h("<atomic>",             "atomic", "memory_order", "memory_order_relaxed",
                           "memory_order_acquire", "memory_order_release")
_h("<bit>",                "bit_ceil", "countl_zero", "countr_zero")
_h("<chrono>",             "chrono")
_h("<condition_variable>", "condition_variable")
_h("<cstddef>",            "byte", "max_align_t")
_h("<cstdio>",             "fflush", "fputws")
_h("<cstdlib>",            "abort", "aligned_alloc", "free", "getenv")
_h("<cstring>",            "memcpy", "memset", "strlen")
_h("<cwchar>",             "wcstod", "wcstoll")
_h("<cwctype>",            "iswalpha", "iswdigit", "iswspace")
_h("<deque>",              "deque")
_h("<exception>",          "exception")
_h("<filesystem>",         "filesystem")
_h("<format>",             "format")
_h("<fstream>",            "ofstream", "wofstream")
_h("<functional>",         "hash")
_h("<future>",             "future", "promise")
_h("<iomanip>",            "hex")
_h("<iostream>",           "cout", "wcout", "endl", "ios")
_h("<iterator>",           "size")
_h("<limits>",             "numeric_limits")
_h("<locale>",             "ctype", "locale", "num_get", "num_put", "use_facet")
_h("<memory>",             "construct_at", "destroy_at", "make_shared",
                           "make_unique", "shared_ptr", "unique_ptr", "weak_ptr")
_h("<mutex>",              "lock_guard", "mutex", "once_flag",
                           "recursive_mutex", "unique_lock")
_h("<optional>",           "nullopt")
_h("<shared_mutex>",       "shared_lock", "shared_mutex")
_h("<source_location>",    "source_location")
_h("<sstream>",            "ostringstream")
_h("<stack>",              "stack")
_h("<string>",             "string")
_h("<system_error>",       "error_code")
_h("<thread>",             "thread", "this_thread")
_h("<tuple>",              "tuple_element_t")
_h("<type_traits>",        "decay_t", "is_invocable_r_v", "is_same_v",
                           "is_trivially_destructible_v")
_h("<unordered_map>",      "unordered_map")
_h("<unordered_set>",      "unordered_set")
_h("<utility>",            "forward", "make_pair", "move", "pair")
_h("<vector>",             "vector")

# std::get is declared by <tuple>, <array>, <utility> and <variant>, one
# overload each, and which one a site needs depends on what it is called on.
# 197 sites, so it is the bulk of the job and the one worth being told about.
AMBIGUOUS = {"get": "<tuple>/<array>/<utility>/<variant> -- depends on the operand"}

SKIP_DIR = ("/Native/", "/bootstrap/", "/llvm-runtimes/", "/build/")


def mask(src):
    """Byte mask over src: True where a libcxx:: match is REAL Kairo code.

    False inside line comments, string literals and inline "c++" bodies. Kept
    deliberately simple -- it only has to be right about where a `libcxx::`
    token sits, not tokenize Kairo."""
    ok = bytearray(b"\x01") * len(src)
    cpp = []                         # (start, end) of inline "c++" bodies
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == "/" and i + 1 < n and src[i + 1] == "/":
            j = src.find("\n", i)
            j = n if j < 0 else j
            for k in range(i, j): ok[k] = 0
            i = j
            continue
        if c == '"':
            j = i + 1
            while j < n and src[j] != '"':
                j += 2 if src[j] == "\\" else 1
            j = min(j + 1, n)
            for k in range(i, j): ok[k] = 0
            i = j
            continue
        if src.startswith("inline", i) and re.match(r'inline\s+"c\+\+"\s*\{', src[i:]):
            b = src.find("{", i)
            depth, j = 1, b + 1
            while j < n and depth:
                if   src[j] == "{": depth += 1
                elif src[j] == "}": depth -= 1
                j += 1
            for k in range(i, j): ok[k] = 0
            cpp.append((i, j))
            i = j
            continue
        i += 1
    return ok, cpp


def scan(path):
    src = path.read_text(encoding="utf-8")
    ok, cpp = mask(src)
    live, dead = [], 0
    for m in SYM.finditer(src):
        if ok[m.start()]: live.append(m)
        elif any(a <= m.start() < b for a, b in cpp): dead += 1
    return src, live, dead


def rewrite(src, live):
    out, i = [], 0
    for m in live:
        out.append(src[i:m.start()])
        out.append("cxx::std::" + m.group(1))
        i = m.end()
    out.append(src[i:])
    return "".join(out)


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__ or "usage: libcxx_to_cxx_std.py <root> [--apply] [--only SUBSTR]")
        return 2
    root = pathlib.Path(args[0])
    apply = "--apply" in args
    only = args[args.index("--only") + 1] if "--only" in args else None

    files = sites = manual = 0
    need_imports = []
    unknown = {}

    for p in sorted(root.rglob("*.k")):
        sp = str(p)
        if any(d in sp for d in SKIP_DIR): continue
        if only and only not in sp: continue

        src, live, dead = scan(p)
        if not live and not dead: continue

        files += 1; sites += len(live); manual += dead

        have = set(FFI.findall(src))
        want, amb, unk = set(), set(), set()
        for m in live:
            s = m.group(1)
            if s in AMBIGUOUS: amb.add(s)
            elif s in HEADER:  want.add(HEADER[s])
            else:              unk.add(s)
        for s in unk: unknown.setdefault(s, []).append(sp)

        missing = sorted(h for h in want if h.strip("<>") not in
                         {x.strip("<>") for x in have})

        flags = []
        if dead:    flags.append(f"{dead} in inline c++ (MANUAL)")
        if missing: flags.append(f"needs {' '.join(missing)}")
        if amb:     flags.append("ambiguous: " + " ".join(sorted(amb)))
        if unk:     flags.append("UNKNOWN: " + " ".join(sorted(unk)))
        print(f"{len(live):4d} {sp}" + ("   [" + "; ".join(flags) + "]" if flags else ""))

        if missing: need_imports.append((sp, missing))
        if apply and live:
            p.write_text(rewrite(src, live), encoding="utf-8")

    print()
    print(f"{sites} site(s) in {files} file(s); {manual} left in inline \"c++\" blocks")
    if unknown:
        print(f"\n{len(unknown)} symbol(s) with no header mapping -- add them to HEADER:")
        for s, where in sorted(unknown.items()):
            print(f"  libcxx::{s}   ({len(where)} file(s))")
    if need_imports:
        print(f"\n{len(need_imports)} file(s) need an ffi import added BY HAND before the")
        print("rename resolves. `cxx` binds only in a TU with an ffi import, and")
        print("`cxx::std::X` only resolves if X's header is in that TU's closure:")
        for sp, missing in need_imports:
            print(f"  {sp}")
            for h in missing:
                print(f'      ffi "c++" import "{h}"')
    if not apply:
        print("\n(report only -- pass --apply to rewrite)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
