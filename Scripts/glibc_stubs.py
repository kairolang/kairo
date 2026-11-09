#!/usr/bin/env python3
"""glibc ABI lists and stub DSOs (Compiler/Spec/SysRoot.md section 4.6).

The glibc provider never ships glibc's DSOs: it links stand-ins that export the same
versioned symbols, which is all a link against glibc reads. This module is the reference
implementation the Kairo-side provider (Linker/Sysroot/Providers/) ports:

    read_dso(path)            -> Dso      stdlib ELF reader: SONAME, verdefs, dynsym
    abilist_text(dso)         -> str      glibc's scripts/abilist.awk format
    compat_text(dso)          -> str      the entries the "newest version is default" rule gets wrong
    parse_abilist(text, compat_text) -> list[Entry]
    stub_sources(entries, versions) -> (c_source, version_script)
    build_stub(...)           -> Path     compile + link one stub .so
    compare(a, b)             -> list[str] parity differences ([] = same)

Python stdlib only. Command line:

    python3 Scripts/glibc_stubs.py extract <lib.so> ...     # print abilist
    python3 Scripts/glibc_stubs.py compare <a.so> <b.so>
"""
import os
import re
import struct
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

# abilist.awk drops these: not ABI a program may bind to.
PRIVATE_VERSIONS = ("GLIBC_PRIVATE",)


@dataclass(frozen=True, order=True)
class Entry:
    version: str
    name: str
    kind: str          # "F" function (FUNC, IFUNC), "D" data object, "T" TLS object,
                       # "A" the absolute symbol GNU ld names after each version node
    size: int          # D / T only; 0 for F
    default: bool      # @@ (true) or @ (false, a compat-only binding)


@dataclass
class Dso:
    soname: str
    versions: list     # verdef names in definition order, base (soname) excluded
    entries: list      # Entry, private versions included


# ---------------------------------------------------------------- ELF reading

def read_dso(path: Path) -> Dso:
    data = Path(path).read_bytes()
    if data[:4] != b"\x7fELF":
        raise ValueError(f"{path}: not ELF")
    is64 = data[4] == 2
    end = "<" if data[5] == 1 else ">"
    if is64:
        shoff, = struct.unpack_from(end + "Q", data, 0x28)
        shentsize, shnum, shstrndx = struct.unpack_from(end + "HHH", data, 0x3A)
    else:
        shoff, = struct.unpack_from(end + "I", data, 0x20)
        shentsize, shnum, shstrndx = struct.unpack_from(end + "HHH", data, 0x2E)
    secs = []
    for i in range(shnum):
        o = shoff + i * shentsize
        if is64:
            name, typ, _, _, off, size, link, info, _, entsize = struct.unpack_from(end + "IIQQQQIIQQ", data, o)
        else:
            name, typ, _, _, off, size, link, info, _, entsize = struct.unpack_from(end + "IIIIIIIIII", data, o)
        secs.append(dict(name=name, type=typ, off=off, size=size, link=link, info=info, entsize=entsize))

    def cstr(off):
        return data[off:data.index(b"\0", off)].decode()

    by_type = {}
    for s in secs:
        by_type.setdefault(s["type"], s)
    SHT_DYNSYM, SHT_DYNAMIC, VERSYM, VERDEF = 11, 6, 0x6FFFFFFF, 0x6FFFFFFD
    dynsym = by_type[SHT_DYNSYM]
    dynstr = secs[dynsym["link"]]["off"]

    # verdef: index -> name
    vnames, vorder = {}, []
    vd = by_type.get(VERDEF)
    if vd:
        o = vd["off"]
        for _ in range(vd["info"]):
            _, flags, ndx, _, _, aux, nxt = struct.unpack_from(end + "HHHHIII", data, o)
            vname = cstr(dynstr + struct.unpack_from(end + "I", data, o + aux)[0])
            vnames[ndx] = vname
            if not flags & 1:                     # VER_FLG_BASE: the soname itself
                vorder.append(vname)
            if not nxt:
                break
            o += nxt

    soname = ""
    dyn = by_type.get(SHT_DYNAMIC)
    if dyn:
        fmt, step = (end + "qQ", 16) if is64 else (end + "iI", 8)
        for o in range(dyn["off"], dyn["off"] + dyn["size"], step):
            tag, val = struct.unpack_from(fmt, data, o)
            if tag == 0:
                break
            if tag == 14:                          # DT_SONAME
                soname = cstr(dynstr + val)

    versym = by_type.get(VERSYM)
    n = dynsym["size"] // dynsym["entsize"]
    entries = []
    for i in range(1, n):
        o = dynsym["off"] + i * dynsym["entsize"]
        if is64:
            nm, info, _, shndx, _, size = struct.unpack_from(end + "IBBHQQ", data, o)
        else:
            nm, _, size, info, _, shndx = struct.unpack_from(end + "IIIBBH", data, o)
        if shndx == 0:                             # undefined: an import, not ABI
            continue
        bind, typ = info >> 4, info & 0xF
        if bind not in (1, 2) or not versym:      # GLOBAL / WEAK only
            continue
        vs, = struct.unpack_from(end + "H", data, versym["off"] + 2 * i)
        idx = vs & 0x7FFF
        if idx < 2 or idx not in vnames or vnames[idx] in (soname,):
            continue
        name = cstr(dynstr + nm)
        if shndx == 0xFFF1 and name == vnames[idx]:
            kind, size = "A", 0                    # GNU ld's absolute version-name symbol
        elif typ in (2, 10):                       # FUNC, GNU_IFUNC
            kind, size = "F", 0
        elif typ == 1:
            kind = "D"
        elif typ == 6:
            kind = "T"
        else:
            kind = "D"
        entries.append(Entry(vnames[idx], name, kind, size, not vs & 0x8000))
    return Dso(soname, vorder, sorted(set(entries)))


# ---------------------------------------------------------------- abilist I/O

def _ver_key(v: str):
    m = re.match(r"([A-Z_]+?)_?(\d+(?:\.\d+)*)$", v)
    return (m.group(1), tuple(int(x) for x in m.group(2).split("."))) if m else (v, ())


def public(entries):
    return [e for e in entries if e.version not in PRIVATE_VERSIONS]


def abilist_text(dso: Dso) -> str:
    """glibc's abilist.awk lines: `VERSION SYMBOL F` / `VERSION SYMBOL D 0x<size>` / T for
    TLS, private versions dropped, sorted as glibc's `sort -u` leaves them (bytewise)."""
    lines = set()
    for e in public(dso.entries):
        lines.add(f"{e.version} {e.name} {e.kind}" + (f" {e.size:#x}" if e.kind in "DT" else ""))
    return "".join(l + "\n" for l in sorted(lines, key=str.encode))


def default_rule(entries) -> dict:
    """name -> the version the rule makes default: the newest one the symbol has."""
    best = {}
    for e in entries:
        if e.name not in best or _ver_key(e.version) > _ver_key(best[e.name]):
            best[e.name] = e.version
    return best


def compat_text(dso: Dso) -> str:
    """abilist.awk drops @ vs @@. Rule: a symbol's newest version is its default (@@), the
    rest are compat (@). This file lists `VERSION SYMBOL @|@@` for every entry where the DSO
    disagrees with the rule (compat-only symbols, mostly), so the pair is lossless."""
    pub = public(dso.entries)
    rule = default_rule(pub)
    out = set()
    for e in pub:
        if e.default != (rule[e.name] == e.version):
            out.add(f"{e.version} {e.name} {'@@' if e.default else '@'}")
    return "".join(l + "\n" for l in sorted(out, key=str.encode))


def parse_abilist(text: str, compat: str = "") -> list:
    raw = []
    for line in text.splitlines():
        p = line.split()
        if not p or p[0].startswith("#"):
            continue
        raw.append((p[0], p[1], p[2], int(p[3], 16) if len(p) > 3 else 0))
    rule = default_rule([Entry(v, n, k, s, True) for v, n, k, s in raw])
    over = {}
    for line in compat.splitlines():
        p = line.split()
        if len(p) == 3:
            over[(p[0], p[1])] = p[2] == "@@"
    return sorted(Entry(v, n, k, s, over.get((v, n), rule[n] == v)) for v, n, k, s in raw)


# ---------------------------------------------------------------- stubs

def stub_sources(entries, versions) -> tuple[str, str]:
    """A C file with one definition per (symbol, version), bound with .symver, and the
    version script declaring every node in definition order (each inheriting the previous,
    as glibc's own Versions files chain them)."""
    c = ["/* generated by Scripts/glibc_stubs.py: a link-time stand-in, never run */"]
    absnames = {}
    for i, e in enumerate(entries):
        if e.kind == "A":
            # lld does not invent GNU ld's version-name symbols; define them absolute and
            # let the version script bind each to its own node.
            c.append(f'__asm__(".globl \\"{e.name}\\"\\n.set \\"{e.name}\\", 0");')
            absnames.setdefault(e.version, []).append(e.name)
            continue
        s = f"__kairo_stub_{i}"
        if e.kind == "F":
            c.append(f"void {s}(void) {{}}")
        elif e.kind == "T":
            c.append(f"__thread char {s}[{e.size}] = {{0}};")
        else:
            c.append(f"char {s}[{e.size}] = {{0}};")
        c.append(f'__asm__(".symver {s}, {e.name}{"@@" if e.default else "@"}{e.version}");')
        if not e.default:
            # lld applies `local: *` to a non-default name@VER the node does not list
            absnames.setdefault(e.version, []).append(e.name)
    nodes = list(versions) + sorted({e.version for e in entries} - set(versions), key=_ver_key)
    vs, prev = [], None
    for i, v in enumerate(nodes):
        body = "".join(f"  {n};\n" for n in absnames.get(v, []))
        body = ("  global:\n" + body if body else "") + ("  local: *;\n" if i == 0 else "")
        vs.append(f"{v} {{\n{body}}}" + (f" {prev};" if prev else ";"))
        prev = v
    return "\n".join(c) + "\n", "\n".join(vs) + "\n"


def build_stub(cc: list, target: str, soname: str, entries, versions, work: Path) -> Path:
    """cc: the compiler driver argv prefix (kcc or clang). Links with lld, no libraries."""
    work.mkdir(parents=True, exist_ok=True)
    src, vscript = stub_sources(entries, versions)
    (work / "stub.c").write_text(src)
    (work / "stub.map").write_text(vscript)
    out = work / soname
    r = subprocess.run([*cc, f"--target={target}", "-fPIC", "-shared", "-nostdlib", "-fuse-ld=lld",
                        "-O0", "-w", "-o", str(out), str(work / "stub.c"),
                        f"-Wl,--version-script={work / 'stub.map'}", f"-Wl,-soname,{soname}"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"stub {soname} for {target} failed:\n{r.stderr[-2000:]}")
    return out


def compare(a: Dso, b: Dso) -> list:
    """What a link can observe: SONAME and the public versioned dynsym (name, version,
    @/@@, kind, object size). Bytes, private symbols and binding are not compared."""
    diffs = []
    if a.soname != b.soname:
        diffs.append(f"soname {a.soname} != {b.soname}")
    ea, eb = set(public(a.entries)), set(public(b.entries))
    for e in sorted(ea - eb):
        diffs.append(f"only in first: {e}")
    for e in sorted(eb - ea):
        diffs.append(f"only in second: {e}")
    return diffs


def main() -> int:
    if len(sys.argv) >= 3 and sys.argv[1] == "extract":
        for p in sys.argv[2:]:
            sys.stdout.write(abilist_text(read_dso(Path(p))))
        return 0
    if len(sys.argv) == 4 and sys.argv[1] == "compare":
        d = compare(read_dso(Path(sys.argv[2])), read_dso(Path(sys.argv[3])))
        print("\n".join(d) or "same")
        return 1 if d else 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
