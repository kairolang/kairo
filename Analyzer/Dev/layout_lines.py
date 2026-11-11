#!/usr/bin/env python3
"""Measures a clangd-bridge layout header against its .k file.

clangd reports a header location by its PHYSICAL line, so a jump from C++
into a .k file lands on the right line only when the declaration clangd
jumps to sits on the physical line its Kairo declaration has. This parses
each layout header with libclang (the bundled one by default) under kcc's
flags and, for every exported Kairo declaration it can match (types,
functions, methods, fields, enum variants, aliases), compares the line of
the C++ declaration clangd would jump to -- the definition when the header
has one, else the first declaration in the header -- with the .k line. It
also says where each `///` doc above a matched declaration went: on a
declaration in the header, on a forward declaration in the prelude, or
nowhere.

    layout_lines.py --flags-from WORKER.json --headers DIR --sources DIR [-v]

The header for `a/b.k` is `DIR/a/b.hh` (`a/module.k` is `a.hh`). The
flags are a header job's `cxx_flags` (kals --worker writes them), or
`--flags "..."`. Matching is by name inside the enclosing Kairo record;
C++ the emitter invents (allocation operators, assignment, the `__kairo_`
helpers) has no Kairo declaration and is not counted. A Kairo `fn op +` is
C++ `operator+`; a constructor is the record's name; `op finally` is the
destructor; an `extend X` block's functions are `__kairo_ext_X` members.
"""

import argparse
import json
import os
import re
import sys


def load_cindex(lib):
    import clang.cindex as ci
    if lib:
        ci.Config.set_library_file(lib)
    return ci


# --- the .k side -------------------------------------------------------------

DECL_RE = re.compile(
    r"(?:^|(?<=[;{}]))\s*(?:@\w+(?:\([^)]*\))?\s*)*"
    r"(?:(?:pub|priv|prot|inline|static|eval|override|virtual|unsafe|extern|const|async)\s+)*"
    r"(fn|class|struct|enum|union|interface|var|let|type|extend|const|static|thread)\s+(?:<[^>]*>\s*)?"
    r"(op\s+[^\s(]+(?:\s+[^\s(]+)?|[A-Za-z_]\w*)")
VARIANT_RE = re.compile(r"(?:^|(?<=[,{]))\s*([A-Za-z_]\w*)\s*(?==|,|\(|\{|$|\})")


def strip_line(s):
    r"""\p s without strings, chars and its // comment."""
    out, i, n = [], 0, len(s)
    while i < n:
        c = s[i]
        if c == "/" and i + 1 < n and s[i + 1] == "/":
            break
        if c in "\"'":
            q, i = c, i + 1
            while i < n and s[i] != q:
                i += 2 if s[i] == "\\" else 1
            out.append(" ")
            i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


def k_decls(path):
    r"""[(name, kind, line, parent)] of \p path; parent is the innermost
    record (class/struct/enum/union/interface/extend) name, or ""."""
    lines = open(path, encoding="utf-8", errors="replace").read().split("\n")
    out = []
    stack = []      # (kind, name) per open brace; kind "" for a block
    pending = None  # a record keyword seen, its brace not yet open
    in_block_comment = False
    for no, raw in enumerate(lines, 1):
        s = strip_line(raw)
        if in_block_comment:
            if "*/" not in s:
                continue
            s = s[s.index("*/") + 2:]
            in_block_comment = False
        if "/*" in s and "*/" not in s[s.index("/*"):]:
            s = s[:s.index("/*")]
            in_block_comment = True
        in_enum = bool(stack) and stack[-1][0] == "enum"
        # Declarations on this line, at their own position.
        events = []
        for m in DECL_RE.finditer(s):
            events.append((m.start(2), "decl", m.group(1), m.group(2)))
        if in_enum:
            for m in VARIANT_RE.finditer(s):
                if m.group(1) not in ("pub", "fn", "var", "priv"):
                    events.append((m.start(1), "variant", "variant", m.group(1)))
        for i, c in enumerate(s):
            if c in "{}":
                events.append((i, c, None, None))
        events.sort(key=lambda e: e[0])
        for _, what, kind, name in events:
            if what == "decl":
                if not any(k == "fn" for k, _ in stack) or kind in ("class", "struct", "enum", "union"):
                    if kind != "extend":
                        out.append((name, kind, no, next((nm for k, nm in reversed(stack) if k and k != "fn"), "")))
                if kind in ("class", "struct", "enum", "union", "interface", "extend", "fn"):
                    pending = (kind, name)
                elif kind in ("var", "let"):
                    pending = None
            elif what == "variant":
                if stack and stack[-1][0] == "enum":
                    out.append((name, "variant", no, stack[-1][1]))
            elif what == "{":
                if pending:
                    stack.append(pending)
                    pending = None
                else:
                    stack.append(("", ""))
            elif what == "}":
                if stack:
                    stack.pop()
        # A fn with no brace on its line (a prototype, an `= expr` body)
        # opens nothing, unless its parameter list goes on.
        if pending and pending[0] == "fn" and not s.rstrip().endswith((",", "(")):
            pending = None
    # Kairo's `op +` and C++'s `operator+` compare without spaces; a doc
    # belongs to the first declaration on its line.
    norm, seen = [], set()
    for name, kind, line, parent in out:
        if name.startswith("op "):
            name = "op " + name[3:].replace(" ", "")
        norm.append((name, kind, line, parent, line not in seen))
        seen.add(line)
    return norm, lines


def doc_above(lines, k):
    r"""The `///` block kals' hover reads above 1-based line \p k, else []."""
    rev, j = [], k
    while j > 1:
        t = lines[j - 2].lstrip(" \t")
        if t.startswith("///"):
            rev.append(t)
            j -= 1
            continue
        if t.startswith("@") and not rev:
            j -= 1
            continue
        break
    if not rev or rev[-1].startswith("/// ---"):
        return []
    return list(reversed(rev))


# --- the C++ side ------------------------------------------------------------

def k_name(ci, c):
    """The Kairo spelling a C++ cursor's declaration has, else None."""
    K = ci.CursorKind
    sp = c.spelling
    if c.kind == K.DESTRUCTOR:
        return "op finally"
    if sp.startswith("operator"):
        op = sp[len("operator"):].strip()
        if not op or op[0].isalpha():
            return None  # conversion, new/delete
        return "op " + op.replace(" ", "")
    if c.kind == K.CONSTRUCTOR or "<" in sp:
        return sp.split("<")[0]
    return sp


KINDS = None


def cxx_entities(ci, tu, header, prelude):
    """{usr: [cursors]} of the declarations located in the header or prelude."""
    K = ci.CursorKind
    global KINDS
    KINDS = {K.STRUCT_DECL, K.CLASS_DECL, K.UNION_DECL, K.ENUM_DECL, K.CLASS_TEMPLATE,
             K.ENUM_CONSTANT_DECL, K.FUNCTION_DECL, K.FUNCTION_TEMPLATE, K.CXX_METHOD,
             K.CONSTRUCTOR, K.DESTRUCTOR, K.FIELD_DECL, K.VAR_DECL, K.TYPE_ALIAS_DECL,
             K.TYPEDEF_DECL, K.TYPE_ALIAS_TEMPLATE_DECL}
    files = {header, prelude}
    out = {}

    def walk(c):
        for ch in c.get_children():
            f = ch.location.file
            fn = os.path.realpath(f.name) if f else None
            if fn is not None and fn not in files:
                continue  # an include's own declarations
            if ch.kind in KINDS and fn in files:
                usr = ch.get_usr() or ("%s@%s:%d" % (ch.spelling, fn, ch.location.line))
                out.setdefault(usr, []).append(ch)
            if ch.kind in (K.NAMESPACE, K.STRUCT_DECL, K.CLASS_DECL, K.UNION_DECL, K.ENUM_DECL,
                           K.CLASS_TEMPLATE, K.LINKAGE_SPEC, K.UNEXPOSED_DECL):
                walk(ch)
    walk(tu.cursor)
    return out


def parent_name(ci, c):
    p = c.semantic_parent
    K = ci.CursorKind
    if p is None or p.kind in (K.NAMESPACE, K.TRANSLATION_UNIT, K.LINKAGE_SPEC):
        return ""
    n = p.spelling
    if n.startswith("__kairo_ext_"):
        n = n[len("__kairo_ext_"):]
    return n


def measure(ci, header, kfile, flags, verbose):
    header = os.path.realpath(header)
    prelude = header + ".prelude"
    idx = ci.Index.create()
    tu = idx.parse(header, args=["-x", "c++"] + flags,
                   options=ci.TranslationUnit.PARSE_SKIP_FUNCTION_BODIES * 0)
    errs = [d for d in tu.diagnostics if d.severity >= 3]
    decls, klines = k_decls(kfile)
    by_key, first_on = {}, set()
    for name, kind, line, parent, first in decls:
        by_key.setdefault((name, parent), []).append(line)
        if first:
            first_on.add((name, parent, line))
    ents = cxx_entities(ci, tu, header, prelude)
    r = dict(on=0, wrong=0, decl_only=0, unmatched=0, doc_place=0, doc_prelude=0, doc_dropped=0, doc_wrong=0,
             var_on=0, var_wrong=0, var_doc_place=0, var_doc_dropped=0, errors=len(errs))
    wrong, dropped, on_set = [], [], []
    claimed = {}
    groups = []
    for usr, cs in ents.items():
        in_h = [c for c in cs if os.path.realpath(c.location.file.name) == header]
        if not in_h:
            continue
        defs = [c for c in in_h if c.is_definition()]
        target = defs[0] if defs else in_h[0]
        nm = k_name(ci, target)
        if nm is None or nm.startswith("__kairo") or "__kairo" in parent_name(ci, target):
            continue
        cands = by_key.get((nm, parent_name(ci, target)))
        if not cands:
            r["unmatched"] += 1
            if verbose > 1:
                print("  unmatched %s %s::%s @%d" % (target.kind.name, parent_name(ci, target), nm, target.location.line))
            continue
        groups.append((target, cs, nm, cands))
    # Exact lines first, so an overload never takes its sibling's line.
    for target, cs, nm, cands in groups:
        key = (nm, parent_name(ci, target))
        if target.location.line in cands and target.location.line not in claimed.get(key, set()):
            claimed.setdefault(key, set()).add(target.location.line)
    for target, cs, nm, cands in groups:
        key = (nm, parent_name(ci, target))
        variant = target.kind == ci.CursorKind.ENUM_CONSTANT_DECL
        line = target.location.line
        if line in cands:
            kl = line
            r["var_on" if variant else "on"] += 1
            on_set.append("%s %s::%s %d" % (target.kind.name, key[1], nm, kl))
        else:
            free = [x for x in cands if x not in claimed.get(key, set())]
            kl = free[0] if free else cands[0]
            claimed.setdefault(key, set()).add(kl)
            r["var_wrong" if variant else "wrong"] += 1
            kind = target.kind.name
            if any(c.location.line == kl and os.path.realpath(c.location.file.name) == header for c in cs):
                # Its declaration is on the line; the definition clangd
                # prefers for a jump is not.
                r["decl_only"] += 1
                kind = "DEF " + kind
                on_set.append("decl %s %s::%s %d" % (target.kind.name, key[1], nm, kl))
            wrong.append((kind, key[1], nm, line, kl))
        doc = doc_above(klines, kl) if (key[0], key[1], kl) in first_on else []
        if not doc:
            continue
        raw = None
        for c in cs:
            raw = raw or c.raw_comment or None
        first = doc[0].strip()
        if raw is None:
            r["var_doc_dropped" if variant else "doc_dropped"] += 1
            dropped.append((target.kind.name, key[1], nm, kl))
        elif first not in raw:
            r["doc_wrong"] += 1
            wrong.append(("DOC " + target.kind.name, key[1], nm, line, kl))
            if verbose > 2:
                print("    want %r\n    got  %r" % (first, raw[:200]))
        elif not variant and first in open(prelude).read() and not any(
                os.path.realpath(c.location.file.name) == header and c.raw_comment for c in cs):
            r["doc_prelude"] += 1
        else:
            r["var_doc_place" if variant else "doc_place"] += 1
    if verbose:
        for e in errs[:5]:
            print("  error: %s" % e)
        for w in wrong:
            print("  wrong  %-22s %s::%s header %d, .k %d" % w)
        if verbose > 1:
            for d in dropped:
                print("  nodoc  %-22s %s::%s .k %d" % d)
    r["_on"] = on_set
    return r


def pairs(headers, sources):
    for dp, _, fs in os.walk(sources):
        for f in sorted(fs):
            if not f.endswith(".k"):
                continue
            k = os.path.join(dp, f)
            rel = os.path.relpath(k, sources)[:-2]
            if os.path.basename(rel) == "module":
                rel = os.path.dirname(rel)
            h = os.path.join(headers, (rel if rel else os.path.basename(sources)) + ".hh")
            if os.path.exists(h):
                yield h, k


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter,
                                 fromfile_prefix_chars="@")  # @file: one argument per line
    ap.add_argument("--flags-from", help="a header job's JSON (cxx_flags)")
    ap.add_argument("--flags", default="", help="extra clang words, space-separated")
    ap.add_argument("--headers", required=True)
    ap.add_argument("--sources", action="append", default=[])
    ap.add_argument("--pair", action="append", default=[], help="HEADER=FILE.k, measured as such")
    ap.add_argument("--libclang", default=None)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--on-set", help="write each declaration on its line here, one per line (diff two runs)")
    ap.add_argument("-v", action="count", default=0)
    a = ap.parse_args()
    flags = []
    if a.flags_from:
        flags += json.load(open(a.flags_from))["cxx_flags"]
    flags += a.flags.split()
    flags += ["-I", os.path.realpath(a.headers), "-Wno-pragma-once-outside-header"]
    ci = load_cindex(a.libclang)
    tot = {}
    rows = []
    on_lines = []
    todo = [p.split("=", 1) for p in a.pair]
    for src in a.sources:
        todo += list(pairs(a.headers, src))
    for h, k in todo:
        if a.v:
            print(os.path.relpath(h, a.headers))
        r = measure(ci, h, k, flags, a.v)
        rows.append((os.path.relpath(h, a.headers), r))
        for x, v in r.items():
            if x == "_on":
                on_lines.extend(os.path.relpath(h, a.headers) + " " + e for e in v)
                continue
            tot[x] = tot.get(x, 0) + v
    if a.on_set:
        open(a.on_set, "w").write("\n".join(sorted(on_lines)) + "\n")
    if a.json:
        print(json.dumps({"headers": dict(rows), "total": tot}, indent=1))
        return
    cols = ["on", "wrong", "decl_only", "var_on", "var_wrong", "doc_place", "doc_prelude", "doc_dropped",
            "var_doc_place", "var_doc_dropped", "doc_wrong", "unmatched", "errors"]
    print("%-36s " % "header" + " ".join("%6s" % c[:6] for c in cols))
    for n, r in rows + [("TOTAL (%d headers)" % len(rows), tot)]:
        print("%-36s " % n[-36:] + " ".join("%6d" % r.get(c, 0) for c in cols))


if __name__ == "__main__":
    sys.exit(main())
