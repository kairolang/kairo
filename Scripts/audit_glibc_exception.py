#!/usr/bin/env python3
"""Licence audit of the glibc start-file sources the sysroot generator ships.

For every `[compile.*]` source in every table build/sysroot-share/glibc/crt/<era>/<arch>.toml,
and the .c/.S/.s files those sources `#include` (quoted or angle, resolved through the compile's
own -I{src}/... directories inside the shipped glibc/src/<era>/), check that the file carries
either

  - glibc's link exception ("In addition to the permissions in the GNU Lesser General Public
    License, the Free Software Foundation gives you unlimited permission to link the compiled
    version of this file with other programs"), compared with comment markers and line breaks
    ignored, or
  - Kairo's own SPDX identifier (SPDX-License-Identifier: Apache-2.0 WITH
    AdditionRef-Kairo-Runtime-exception), which is what Scripts/glibc-own/ files carry.

Any file with neither is reported (and the exit status is 1). Expected result: none; a file
listed means a program built against the sysroot statically contains LGPL-2.1-or-later code
with no link exception (NOTICE, "GNU C Library start files").

NOT audited: headers. glibc's internal headers (sysdep.h, libc-symbols.h, ...) are read by these
compiles and can expand into code (inline functions, macros that emit instructions). They are
.h files, so this script skips them; their effect on the objects is covered by comparing the
built crt objects with the originals (Tests/CLI/Sysroot/glibc_own_start_files.k), not here.

    python3 Scripts/audit_glibc_exception.py [--share build/sysroot-share] [-v]
"""
import argparse
import re
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

EXCEPTION = ("in addition to the permissions in the gnu lesser general public license, the free "
             "software foundation gives you unlimited permission to link the compiled version of "
             "this file with other programs")
KAIRO_SPDX = "SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception"
CODE = (".c", ".S", ".s")
INCLUDE = re.compile(r'^\s*#\s*include\s*[<"]([^>"]+)[>"]', re.M)


def norm(text: str) -> str:
    """Lower-cased text with comment decoration (/* */ // # ; *) and line breaks collapsed."""
    text = re.sub(r"/\*|\*/|//|^\s*[#;*@]+(?=\s)", " ", text, flags=re.M)
    text = re.sub(r"(?m)^\s*\*", " ", text)
    return re.sub(r"\s+", " ", text).strip().lower()


def licensed(text: str) -> str | None:
    """'exception', 'kairo' or None."""
    if KAIRO_SPDX in text:
        return "kairo"
    if EXCEPTION in norm(text):
        return "exception"
    return None


def sources(table: dict, src: str) -> list[tuple[str, list[str]]]:
    """(path relative to glibc/src/<era>, its -I dirs relative likewise) per compile."""
    out = []
    for c in table.get("compile", {}).values():
        args = c["args"]
        incs = [a[len("-I{src}/"):] for a in args if a.startswith("-I{src}/")]
        for a in args:
            if a.startswith("{src}/") and a.endswith(CODE):
                out.append((a[len("{src}/"):], incs))
    return out


def walk(era_src: Path, rel: str, incs: list[str], seen: dict) -> None:
    """Record rel and the .c/.S files it includes (depth first, each once)."""
    if rel in seen:
        return
    p = era_src / rel
    if not p.is_file():
        seen[rel] = None            # named by a table or include but not shipped
        return
    text = p.read_text(errors="replace")
    seen[rel] = licensed(text)
    for inc in INCLUDE.findall(text):
        if not inc.endswith(CODE):
            continue
        for d in [str(Path(rel).parent)] + incs:
            cand = (Path(d) / inc).as_posix()
            if (era_src / cand).is_file():
                walk(era_src, cand, incs, seen)
                break


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--share", type=Path, default=ROOT / "build" / "sysroot-share")
    ap.add_argument("-v", "--verbose", action="store_true", help="list every audited file")
    a = ap.parse_args()
    glibc = a.share / "glibc"
    tables = sorted((glibc / "crt").glob("*/*.toml"))
    if not tables:
        sys.exit(f"audit_glibc_exception: no tables under {glibc / 'crt'}")
    bad: dict[tuple[str, str], list[str]] = {}
    total = kairo = 0
    for t in tables:
        era, arch = t.parent.name, t.stem
        era_src = glibc / "src" / era
        seen: dict = {}
        for rel, incs in sources(tomllib.loads(t.read_text()), str(era_src)):
            walk(era_src, rel, incs, seen)
        for rel, lic in sorted(seen.items()):
            total += 1
            kairo += lic == "kairo"
            if a.verbose:
                print(f"{era}/{arch}: {rel}: {lic or 'NONE'}")
            if lic is None:
                bad.setdefault((era, rel), []).append(arch)
    print(f"audited {len(tables)} tables, {total} source references ({kairo} Kairo's own)")
    for (era, rel), arches in sorted(bad.items()):
        print(f"NO EXCEPTION: {era}/{rel}  [{' '.join(arches)}]")
    print(f"{len(bad)} file(s) with neither the link exception nor Kairo's SPDX id")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
