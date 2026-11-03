#!/usr/bin/env python3
# static_cast::<T>(x) / reinterpret_cast::<T>(x) / const_cast::<T>(x)
#   ->  Stage 1 `as`                                (Stage 0 -> Stage 1 corpus)
#
# Correct by construction, or not at all. The Stage 1 spelling of a cast
# depends on what the OPERAND is, and a lexer cannot know that:
#
#   static_cast::<u32>(e)     e: enum E derives u8  -> (e as u8 as u32)
#                                                     (`e as u32` is SC092E)
#   static_cast::<*B>(c)      c: *C, C derives B    -> unsafe (c as unsafe *B)
#   static_cast::<E>(n)       n: a u32, E derives u8 -> (n as u8 as E): into a
#                                                     closed enum a CHECKED
#                                                     cast (crashes on a
#                                                     non-variant); flag sets
#                                                     are @open (enum_open.py)
#
# So every site is classified by clang, from the C++ Stage 0 emits for the
# tree: cast_facts.py writes that table (FACTS.json) and this pass only ever
# consumes it. A site is rewritten when, and only when:
#
#   - its file's casts line up one-to-one with clang's: the same count per
#     keyword, in source order (the k-th static_cast in the file's CODE is
#     the k-th Stage 0 emitted), each pair agreeing on the target's
#     identifiers and pointer depth, and clang's line (from Stage 0's #line
#     markers, which only ever run BEHIND the real line) not after it. One
#     disagreement and the whole file is reported, untouched;
#   - every instantiation clang saw agrees on the kind (a generic body is
#     dumped once per instance at one location). A site only ever seen
#     dependent is reported;
#   - the kind is one of the rules below. Anything else is reported.
#
# The rules (T is the source's own spelling of the target, with every
# pointer raw -- `*X` -> `unsafe *X`, the raw_pointers pass's rule):
#
#   same type (NoOp, operand spelled as T)     (x)
#   int -> int (IntegralCast)                  (x as T); a literal that does
#                                              not fit T is (x as I as T), I
#                                              its C++ type (Stage 1 types a
#                                              literal operand as T, so
#                                              `-1 as u32` is SC075E)
#   enum -> int                                (x as U as T), U = the enum's
#                                              own `derives`; (x as T) when
#                                              U is T; reported when the
#                                              source names no U
#   int -> enum                                (x as U as E), (x as E) when
#                                              x is a U or a literal; for a
#                                              closed E this is the checked
#                                              cast, and enum_open.py makes
#                                              E @open where a non-variant
#                                              value is expected
#   bool -> int                                (x as T)
#   float <-> int, float -> float              (x as T)  (float -> int now
#                                              saturates; C++ was UB)
#   int -> bool (IntegralToBoolean)            ((x) != 0)
#   pointer -> bool (PointerToBoolean)         ((x) != &null)
#   DerivedToBase / BaseToDerived on pointers  unsafe (x as unsafe *T)
#   pointer bitcast, const_cast                unsafe (x as unsafe *T)
#   pointer -> int (PointerToIntegral)         (x as usize), plus `as T` for
#                                              any other T; only a target as
#                                              wide as a host pointer
#   int -> pointer (IntegralToPointer)         unsafe (n as unsafe *T)
#   target C `char` / std::Legacy::char        REPORTED: C char is not
#                                              Kairo's char32
#
# DEPENDENCY: the DerivedToBase / BaseToDerived rule is right only with the
# Stage 1 fix that lowers `unsafe *C as unsafe *B` between related classes as
# static_cast (Tests/Codegen/raw_pointer_base_cast.k). Before it, Stage 1
# reinterpreted, and through a non-first base that read the wrong fields.
#
# Every operand that is not a primary is parenthesized, and so is every
# result; redundant_parens can take them back. Nested casts are rewritten
# inside out. Only the cast is replaced: the operand's own text is kept.
#
#   python3 Scripts/Migration/cast_facts.py --out FACTS.json        # once, on the Stage 0 tree
#   python3 Scripts/Migration/cpp_casts.py <copy> --cast-facts FACTS.json [--log] [--apply]
#   python3 Scripts/Migration/cpp_casts.py --selftest
#
# Run on a COPY of the tree, BEFORE any pass that moves code (ternary_to_if
# reorders, template_alias_macros deletes lines): the matching is by order
# and by line. raw_pointers may run first; it only inserts text on a line.
import atexit, collections, json, os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kairo_lex import code_mask, run
from raw_pointers import TypeWalk

KW = ("static_cast", "reinterpret_cast", "const_cast")
# Stage 0 also takes the C++ spelling without the turbofish: static_cast<T>(x).
SITE = re.compile(r"\b(static_cast|reinterpret_cast|const_cast)\s*(?:::\s*)?<")
IDENTS = re.compile(r"[A-Za-z_]\w*")

INT_CANON = {
    "bool": ("bool", 8), "char": ("cchar", 8), "signed char": ("int", 8), "unsigned char": ("int", 8),
    "char8_t": ("cchar", 8), "char16_t": ("cchar", 16), "char32_t": ("cchar", 32), "wchar_t": ("cchar", 32),
    "short": ("int", 16), "unsigned short": ("int", 16), "int": ("int", 32), "unsigned int": ("int", 32),
    "long": ("int", 64), "unsigned long": ("int", 64), "long long": ("int", 64),
    "unsigned long long": ("int", 64), "__int128": ("int", 128), "unsigned __int128": ("int", 128),
}
FLOAT_CANON = {"float", "double", "long double", "__float128", "_Float16", "__bf16", "__fp16"}
TRIVIAL = {"NoOp", "LValueToRValue", None}

STATS = collections.Counter()      # (rule, "rewritten" | "reported")
REASONS = collections.Counter()
_FACTS = None


# --------------------------------------------------------------------------
# facts
# --------------------------------------------------------------------------
def _argv_opt(flag):
    a = sys.argv
    return a[a.index(flag) + 1] if flag in a and a.index(flag) + 1 < len(a) else None


def facts():
    global _FACTS
    if _FACTS is not None:
        return _FACTS
    p = _argv_opt("--cast-facts") or os.environ.get("KAIRO_CAST_FACTS")
    if not p:
        _FACTS = {}
        return _FACTS
    with open(p, encoding="utf-8") as fh:
        f = json.load(fh)
    root = f["root"]
    by_file = collections.defaultdict(list)
    for s in f["sites"]:
        if not s["stage0"] or not s["file"]:
            continue
        by_file[os.path.relpath(s["file"], root)].append(s)
    for v in by_file.values():
        v.sort(key=lambda s: (s["pline"], s["pcol"]))
    enums = {}
    for qn, e in f["enums"].items():
        if e.get("file"):
            enums[qn] = dict(e, rel=os.path.relpath(e["file"], root))
    _FACTS = {"by_file": by_file, "enums": enums, "pointer_bits": f.get("pointer_bits")}
    return _FACTS


def facts_for(path):
    f = facts()
    if not f:
        return None, "no --cast-facts table (run cast_facts.py first)"
    p = path.replace(os.sep, "/").lstrip("./")
    hits = [k for k in f["by_file"] if k == p or k.endswith("/" + p) or p.endswith("/" + k)]
    if len(hits) > 1:
        return None, "ambiguous: several files in the facts table end with this path"
    if not hits:
        return [], None
    return f["by_file"][hits[0]], None


# --------------------------------------------------------------------------
# source scanning
# --------------------------------------------------------------------------
def _balanced(src, i, op, cl, mask):
    """Index just past the bracket matching src[i] == op, or -1."""
    depth = 0
    n = len(src)
    while i < n:
        c = src[i]
        if mask[i]:
            if c == op:
                depth += 1
            elif c == cl and not (cl == ">" and i > 0 and src[i - 1] == "-"):
                depth -= 1
                if depth == 0:
                    return i + 1
        i += 1
    return -1


def scan(src):
    """Every cast in CODE: dicts with kw, start, end, target, op_start, op_end, line.
    A `static_cast` not followed by a parseable `::<T>(x)` is returned with
    target None, so the file is reported rather than miscounted."""
    mask = code_mask(src)
    out = []
    for m in re.finditer(r"\b(static_cast|reinterpret_cast|const_cast)\b", src):
        if not all(mask[k] for k in range(m.start(), m.end())):
            continue
        site = {"kw": m.group(1), "start": m.start(), "line": src.count("\n", 0, m.start()) + 1,
                "target": None}
        out.append(site)
        mm = SITE.match(src, m.start())
        if not mm:
            continue
        lt = mm.end() - 1
        gt = _balanced(src, lt, "<", ">", mask)
        if gt < 0:
            continue
        j = gt
        while j < len(src) and src[j] in " \t\r\n":
            j += 1
        if j >= len(src) or src[j] != "(":
            continue
        e = _balanced(src, j, "(", ")", mask)
        if e < 0:
            continue
        site.update(target=src[lt + 1:gt - 1].strip(), op_start=j + 1, op_end=e - 1, end=e)
    return out


def type_shape(t):
    """(identifiers, pointer depth) of a type, for pairing the source target
    with Stage 0's C++ spelling of it. `unsafe` / `const` / `struct` and the
    like are spelling, not shape."""
    t = t.replace("_H_RESERVED$", "")    # Stage 0's escape for a C++ keyword (`char`)
    ids = [x for x in IDENTS.findall(t) if x not in ("unsafe", "const", "volatile", "struct", "class", "typename")]
    return ids, t.count("*")


def raw_target(t):
    """The source target with every pointer raw (raw_pointers' rule)."""
    w = TypeWalk(t, [True] * len(t))
    w.typ(0)
    out, last = [], 0
    for a, b, rep in sorted(set(w.edits)):
        out.append(t[last:a])
        out.append(rep)
        last = b
    out.append(t[last:])
    return "".join(out)


def is_primary(op):
    """A name, literal, or postfix chain on one: binds tighter than `as`."""
    op = op.strip()
    if not op or "\n" in op:
        return False
    if op == "&null":           # the null literal, not an address-of
        return True
    i, n, depth = 0, len(op), 0
    if op[0] in "-+!~*&":
        return False
    while i < n:
        c = op[i]
        if c == '"':
            j = i + 1
            while j < n and op[j] != '"':
                j += 2 if op[j] == "\\" else 1
            i = j + 1
            continue
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif depth == 0:
            if c.isalnum() or c in "_.:":
                pass
            elif c == "-" and i + 1 < n and op[i + 1] == ">":
                i += 2
                continue
            elif c == "<" and op[i - 1:i + 1] == ":<":
                # a turbofish: skip its balanced <...>
                d = 0
                while i < n:
                    if op[i] == "<":
                        d += 1
                    elif op[i] == ">":
                        d -= 1
                        if d == 0:
                            break
                    i += 1
            else:
                return False
        i += 1
    return depth == 0


RANGE = {"u8": (0, 2**8 - 1), "u16": (0, 2**16 - 1), "u32": (0, 2**32 - 1), "u64": (0, 2**64 - 1),
         "usize": (0, 2**64 - 1), "u128": (0, 2**128 - 1),
         "i8": (-2**7, 2**7 - 1), "i16": (-2**15, 2**15 - 1), "i32": (-2**31, 2**31 - 1),
         "i64": (-2**63, 2**63 - 1), "isize": (-2**63, 2**63 - 1), "i128": (-2**127, 2**127 - 1)}
# C++ canonical integer type -> the Kairo type of the same width and sign.
KAIRO_INT = {"signed char": "i8", "unsigned char": "u8", "short": "i16", "unsigned short": "u16",
             "int": "i32", "unsigned int": "u32", "long": "i64", "unsigned long": "u64",
             "long long": "i64", "unsigned long long": "u64",
             "__int128": "i128", "unsigned __int128": "u128"}
LIT = re.compile(r"^(0[xX][0-9a-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+|[0-9][0-9_]*)$")


def literal_value(op):
    """The value of an integer-literal operand (`5`, `-1`, `~0`, `(-(2))`),
    or None for anything else."""
    t = op.replace(" ", "").replace("\t", "")
    neg = inv = 0
    while True:
        if t.startswith("(") and t.endswith(")") and _balanced(t, 0, "(", ")", [True] * len(t)) == len(t):
            t = t[1:-1]
        elif t[:1] == "-":
            neg += 1
            t = t[1:]
        elif t[:1] == "~":
            inv += 1
            t = t[1:]
        else:
            break
        if neg + inv > 1:
            return None
    if not LIT.match(t):
        return None
    v = int(t.replace("_", ""), 0)
    return -v if neg else (~v if inv else v)


def through_literal(op, T, op_ty):
    """A literal takes the cast's target type in Stage 1 (`10 as u8` is a u8
    literal), so `-1 as u32` is SC075E where C++'s static_cast wrapped it.
    A literal that does not fit T is first given the type clang gave it."""
    v = literal_value(op)
    if v is None:
        return None
    r = RANGE.get(T.strip())
    if r and r[0] <= v <= r[1]:
        return None
    can = " ".join(re.sub(r"\b(const|volatile)\b", " ", (op_ty or ["", ""])[1]).split())
    return KAIRO_INT.get(can, "")


def paren(op):
    return op.strip() if is_primary(op) else "(" + op.strip() + ")"


# --------------------------------------------------------------------------
# classification
# --------------------------------------------------------------------------
def tclass(ty):
    """('ptr'|'int'|'bool'|'cchar'|'float'|'enum'|'other', detail)."""
    if not ty:
        return ("other", None)
    sug, can = ty
    c = re.sub(r"\b(const|volatile)\b", " ", can)
    c = " ".join(c.split())
    if c.endswith("*"):
        return ("ptr", c.count("*"))
    if c in INT_CANON:
        k, bits = INT_CANON[c]
        return (k, bits)
    if c in FLOAT_CANON:
        return ("float", None)
    c2 = c[5:] if c.startswith("enum ") else c
    k = enum_key(c2)
    if k:
        return ("enum", k)
    return ("other", c2)


def _untemplate(q):
    """`a::B<x, C<y>>::E` -> `a::B::E`: an enum in a class template is keyed
    by the pattern, and every instance's enum is that one."""
    out, d = [], 0
    for ch in q:
        if ch == "<":
            d += 1
        elif ch == ">":
            d -= 1
        elif d == 0:
            out.append(ch)
    return "".join(out).strip()


_EKEY = {}


def enum_key(c):
    """The enums-table key for a canonical type, or None. clang prints some
    canonical enum types qualified and some as written (`TokenKind`,
    `Type::TypeFlags`), so a suffix match is accepted when it is unique --
    or when every candidate declares the same underlying type."""
    if c in _EKEY:
        return _EKEY[c]
    en = facts().get("enums", {})
    q = _untemplate(c)
    res = None
    if q in en:
        res = q
    else:
        cands = [k for k in en if k == q or k.endswith("::" + q)]
        if len(cands) == 1:
            res = cands[0]
        elif cands and len({enum_source(k) for k in cands}) == 1:
            res = cands[0]
    _EKEY[c] = res
    return res


def _sug_name(ty):
    """The written spelling clang kept (sugar), last path component."""
    if not ty:
        return None
    return re.sub(r"\b(const|volatile)\b", "", ty[0]).strip().split("::")[-1].strip()


def effective(inst):
    """Collapse one instance into (kind, op type, target type)."""
    kinds = [inst["kind"]] + list(inst.get("chain") or [])
    real = [k for k in kinds if k not in TRIVIAL]
    if len(real) > 1:
        return ("+".join(real), inst["op"], inst["tgt"])
    return (real[0] if real else "NoOp", inst["op"], inst["tgt"])


_ENUM_SRC = {}


def enum_source(qn):
    """(derives U or None, is_open) for an enum, read from its .k file."""
    if qn in _ENUM_SRC:
        return _ENUM_SRC[qn]
    e = facts()["enums"][qn]
    res = (None, False)
    try:
        path = e["file"]
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().split("\n")
        # The EnumDecl's line is the one its #line marker named; the
        # declaration itself may start a line or two after.
        for ln in range(max(0, e["line"] - 3), min(len(lines), e["line"] + 6)):
            code = lines[ln].split("//")[0]          # not the doc comment naming it
            m = re.search(r"\benum\s+" + re.escape(e["name"]) + r"\b([^{]*)", code)
            if m:
                d = re.search(r"\bderives\s+([A-Za-z_][\w:]*)", m.group(1))
                pre = "\n".join(lines[max(0, ln - 3):ln + 1])
                res = (d.group(1) if d else None, bool(re.search(r"@open\b", pre)))
                break
    except OSError:
        pass
    _ENUM_SRC[qn] = res
    return res


def classify(site, src_site):
    """(rule, replacement-template or None, why). The template has {x} for the
    rewritten operand (already parenthesized as needed) and {T} for the raw
    target."""
    if site["kw"] != src_site["kw"]:
        return ("mismatch", None, "keyword differs from clang's")
    insts = [i for i in site["inst"] if i["kind"] not in ("Dependent", None)]
    if not insts:
        return ("generic", None, "only ever seen dependent (an uninstantiated generic): no kind to go on")
    effs = {(e[0], tuple(e[1] or ()), tuple(e[2] or ())) for e in map(effective, insts)}
    kinds = {e[0] for e in effs}
    if len(kinds) > 1:
        return ("generic", None, f"instances disagree on the kind: {', '.join(sorted(kinds))}")
    kind = kinds.pop()
    opc = {tclass(list(e[1]) if e[1] else None) for e in effs}
    tgc = {tclass(list(e[2]) if e[2] else None) for e in effs}
    if len(opc) > 1 or len(tgc) > 1:
        return ("generic", None, "instances disagree on the operand or target type")
    (ok, od), (tk, td) = opc.pop(), tgc.pop()
    e0 = next(iter(effs))
    T = raw_target(src_site["target"])
    tname = src_site["target"].split("::")[-1].strip()

    if tk == "cchar" or tname == "char":
        return ("char", None, "target is a C char: signedness is the platform's and Kairo's char is char32")
    if site["kw"] == "const_cast":
        if tk == "ptr" and T.startswith("unsafe *"):
            return ("const_cast", "(unsafe ({x} as {T}))", None)
        return ("const_cast", None, "const_cast to a non-pointer")
    if kind == "NoOp":
        if tk == "ptr":
            if T.startswith("unsafe *"):
                return ("pointer same", "(unsafe ({x} as {T}))", None)
            return ("pointer same", None, "pointer target spelled through an alias")
        if ok in ("int", "float", "bool") and tk == ok:
            # usize and u64 are one C++ type and two Kairo ones: NoOp in
            # clang is a real conversion in Kairo unless the spelling agrees.
            if _sug_name(list(e0[1])) == tname:
                return ("same type", "({x})", None)
            if ok == "int":
                via = through_literal(src_site["op_text"], src_site["target"], list(e0[1]))
                if via == "":
                    return ("int -> int", None, "a literal that does not fit the target, of no known C++ type")
                if via:
                    return ("int -> int", "({x} as " + via + " as {T})", None)
            return ("int -> int" if ok == "int" else "float/bool same", "({x} as {T})", None)
        if ok == "enum" and tk == "enum" and od == td:
            return ("same type", "({x})", None)
        if ok == "other" and tk == "other" and od == td:
            return ("same type", "({x})", None)
        return ("noop other", None, f"NoOp from {ok} to {tk}")
    if kind == "IntegralCast":
        if tk == "enum":
            if ok == "enum":
                return ("enum -> enum", None, "enum to enum")
            # Into a closed enum this is Stage 1's CHECKED cast (casting.md
            # "Enum Casts": a non-variant value crashes), which is what the
            # user chose (2026-11-03) over reporting; an enum whose values
            # are not always variants (flag ORs, hashes) is declared @open by
            # enum_open.py, which makes the same spelling unchecked. The
            # operand goes through the enum's own `derives` first unless it
            # already has that type, as enum -> int does the other way.
            u, is_open = enum_source(td)
            rule = "int -> open enum" if is_open else "int -> closed enum"
            if not u:
                return (rule, None, "the enum declares no `derives` underlying type")
            if ok == "bool" or literal_value(src_site["op_text"]) is not None:
                via = None if ok != "bool" else u
            else:
                sug = _sug_name(list(e0[1]))
                can = " ".join(re.sub(r"\b(const|volatile)\b", " ", e0[1][1]).split()) if e0[1] else ""
                kname = sug if sug in RANGE else KAIRO_INT.get(can)
                via = None if kname == u else u
            if via:
                return (rule, "({x} as " + via + " as {T})", None)
            return (rule, "({x} as {T})", None)
        if tk != "int":
            return ("integral other", None, f"IntegralCast to {tk}")
        if ok == "enum":
            u, _ = enum_source(od)
            if not u:
                return ("enum -> int", None, "the enum declares no `derives` underlying type")
            if u == src_site["target"].strip():
                return ("enum -> int", "({x} as {T})", None)
            return ("enum -> int", "({x} as " + u + " as {T})", None)
        if ok in ("int", "bool"):
            via = through_literal(src_site["op_text"], src_site["target"], list(e0[1]))
            if via == "":
                return ("int -> int", None, "a literal that does not fit the target, of no known C++ type")
            if via:
                return ("int -> int", "({x} as " + via + " as {T})", None)
            return ("int -> int" if ok == "int" else "bool -> int", "({x} as {T})", None)
        return ("integral other", None, f"IntegralCast from {ok}")
    if kind in ("FloatingCast", "IntegralToFloating", "FloatingToIntegral"):
        if ok in ("int", "float", "bool") and tk in ("int", "float"):
            return ("float", "({x} as {T})", None)
        return ("float", None, f"{kind} from {ok} to {tk}")
    if kind == "IntegralToBoolean":
        if ok == "int":
            return ("to bool", "(({x}) != 0)", None)
        return ("to bool", None, f"IntegralToBoolean from {ok}")
    if kind == "PointerToBoolean":
        return ("to bool", "(({x}) != &null)", None)
    if kind == "NullToPointer":
        op = src_site.get("op_text", "").strip()
        if op == "&null" and T.startswith("unsafe *"):
            return ("null -> pointer", "(unsafe ({x} as {T}))", None)
        return ("null -> pointer", None, f"NullToPointer from `{op[:30]}`")
    if kind in ("DerivedToBase", "BaseToDerived"):
        if tk == "ptr" and ok == "ptr" and T.startswith("unsafe *"):
            return ("base <-> derived", "(unsafe ({x} as {T}))", None)
        return ("base <-> derived", None, f"{kind} on a non-pointer (a value: slicing)")
    if kind == "BitCast":
        if tk == "ptr" and ok == "ptr" and T.startswith("unsafe *"):
            return ("pointer bitcast", "(unsafe ({x} as {T}))", None)
        return ("pointer bitcast", None, f"BitCast {ok} -> {tk}")
    if kind == "PointerToIntegral":
        pbits = facts().get("pointer_bits")
        if pbits is None:
            return ("pointer -> int", None, "the facts table does not record the host pointer width")
        if tk == "int" and td == pbits:
            if src_site["target"].strip() == "usize":
                return ("pointer -> int", "({x} as usize)", None)
            return ("pointer -> int", "({x} as usize as {T})", None)
        return ("pointer -> int", None, f"target is {td} bits, a host pointer is {pbits}")
    if kind == "IntegralToPointer":
        if ok == "int" and T.startswith("unsafe *"):
            return ("int -> pointer", "(unsafe ({x} as {T}))", None)
        return ("int -> pointer", None, f"IntegralToPointer from {ok}")
    return ("other", None, f"no rule for clang kind {kind} ({ok} -> {tk})")


# --------------------------------------------------------------------------
# the pass
# --------------------------------------------------------------------------
def pair(src, path):
    """[(source site, clang site)] for one file, or (None, why)."""
    sites, why = facts_for(path)
    if sites is None:
        return None, why
    ours = scan(src)
    if not ours:
        return [], None
    if not sites:
        return None, f"{len(ours)} cast(s), but no clang facts for this file (not reached from the entry file?)"
    if any(s["target"] is None for s in ours):
        bad = next(s for s in ours if s["target"] is None)
        return None, f"line {bad['line']}: a {bad['kw']} that is not `::<T>(x)`"
    for s in ours:
        s["op_text"] = src[s["op_start"]:s["op_end"]]
    out, why = _pair_in_order(ours, sites)
    if out is not None:
        return out, None
    # Counts differ when a branch is compiled out on this host (a Windows
    # `eval if`): those casts never reach clang. Then pair only where the
    # line itself agrees, and only when every clang site finds its line.
    out2, why2 = _pair_by_line(ours, sites)
    if out2 is not None:
        return out2, None
    return None, f"{why}; by line: {why2}"


def _pair_in_order(ours, sites):
    for kw in KW:
        a = [s for s in ours if s["kw"] == kw]
        b = [s for s in sites if s["kw"] == kw]
        if len(a) != len(b):
            return None, f"{kw}: {len(a)} in the source, {len(b)} in Stage 0's C++"
    out = []
    for s, c in zip(ours, sites):
        if s["kw"] != c["kw"]:
            return None, f"line {s['line']}: order differs ({s['kw']} here, {c['kw']} in Stage 0's C++)"
        if type_shape(s["target"]) != type_shape(c["written"] or ""):
            return None, (f"line {s['line']}: target `{s['target']}` does not match Stage 0's "
                          f"`{c['written']}`")
        # #line names the line the STATEMENT starts on, so clang's line can
        # trail the cast's but never lead it.
        if c["line"] > s["line"]:
            return None, f"line {s['line']}: clang places the paired cast at line {c['line']}, after it"
        out.append((s, c))
    return out, None


def _pair_by_line(ours, sites):
    a = collections.defaultdict(list)
    b = collections.defaultdict(list)
    for s in ours:
        a[(s["line"], s["kw"])].append(s)
    for c in sites:
        b[(c["line"], c["kw"])].append(c)
    out = []
    for key, cs in b.items():
        ss = a.get(key)
        if not ss:
            return None, f"clang has a {key[1]} at line {key[0]} and the source has none there"
        if len(ss) != len(cs):
            return None, f"line {key[0]}: {len(ss)} {key[1]} in the source, {len(cs)} in Stage 0's C++"
        for s, c in zip(ss, cs):
            if type_shape(s["target"]) != type_shape(c["written"] or ""):
                return None, f"line {key[0]}: target `{s['target']}` does not match Stage 0's `{c['written']}`"
            out.append((s, c))
    for key, ss in a.items():
        if key not in b:
            for s in ss:
                out.append((s, None))
    out.sort(key=lambda p: p[0]["start"])
    return out, None


def rewrite(src, path, report):
    if os.environ.get("KAIRO_MIGRATE_RECHECK"):
        saved = (STATS.copy(), REASONS.copy())
        try:
            return _rewrite(src, path, report)
        finally:
            STATS.clear(); STATS.update(saved[0])
            REASONS.clear(); REASONS.update(saved[1])
    return _rewrite(src, path, report)


def _rewrite(src, path, report):
    log = "--log" in sys.argv
    pairs, why = pair(src, path)
    if pairs is None:
        n = len(scan(src))
        STATS[("file not matched", "reported")] += n
        REASONS["file not matched: " + re.sub(r"line \d+: ", "", why).split(" (")[0][:60]] += n
        report.append(f"{path}: FILE SKIPPED ({n} cast(s)): {why}")
        return src, 0
    decided = []
    for s, c in pairs:
        if c is None:
            rule, tmpl, why = ("not compiled", None, "not in Stage 0's C++ on this host (a compiled-out platform branch?)")
        else:
            rule, tmpl, why = classify(c, s)
        if tmpl is None:
            STATS[(rule, "reported")] += 1
            REASONS[f"{rule}: {why}"] += 1
            if log:
                report.append(f"{path}:{s['line']}: {rule}: {why}  --  {src[s['start']:s['end']][:80]!r}")
            continue
        STATS[(rule, "rewritten")] += 1
        decided.append((s, tmpl))
    if not log:
        rep = sum(1 for s, c in pairs) - len(decided)
        if rep:
            report.append(f"{path}: {rep} cast(s) reported (--log lists them)")

    # Inside out: the innermost (latest-starting) first; each replacement
    # shifts the ends of the sites that enclose it.
    spans = [[s["start"], s["end"], s["op_start"], s["op_end"], s["target"], tmpl] for s, tmpl in decided]
    order = sorted(range(len(spans)), key=lambda k: -spans[k][0])
    for k in order:
        st, en, os_, oe, tgt, tmpl = spans[k]
        op = src[os_:oe]
        new = tmpl.replace("{T}", raw_target(tgt))
        new = new.replace("{x}", op.strip() if (tmpl.startswith("((") or tmpl == "({x})") else paren(op))
        src = src[:st] + new + src[en:]
        delta = len(new) - (en - st)
        for j in range(len(spans)):
            if j != k and spans[j][0] < st and spans[j][1] >= en:
                spans[j][1] += delta
                spans[j][3] += delta
    return src, len(decided)


def summary():
    if not STATS:
        return
    rules = sorted({r for r, _ in STATS})
    print("\ncpp_casts summary")
    print(f"  {'rule':24s} {'rewritten':>10s} {'reported':>10s}")
    tw = tr = 0
    for r in rules:
        w, p = STATS[(r, "rewritten")], STATS[(r, "reported")]
        tw += w
        tr += p
        print(f"  {r:24s} {w:10d} {p:10d}")
    print(f"  {'TOTAL':24s} {tw:10d} {tr:10d}")
    if REASONS:
        print("\n  reported, by reason:")
        for why, n in REASONS.most_common():
            print(f"  {n:6d}  {why}")


# --------------------------------------------------------------------------
# selftest: classification and rendering, from hand-made facts
# --------------------------------------------------------------------------
def _inst(kind, op, tgt, chain=()):
    return {"kind": kind, "op": op, "tgt": tgt, "chain": list(chain)}


U8, U32, U64, USIZE, I32 = ["u8", "unsigned char"], ["u32", "unsigned int"], ["u64", "unsigned long"], \
    ["usize", "unsigned long"], ["i32", "int"]
F64, BOOL, CHAR = ["f64", "double"], ["bool", "bool"], ["char", "char"]
PB, PC, PV = ["B *", "ns::B *"], ["C *", "ns::C *"], ["void *", "void *"]
EK = ["Kind", "ns::Kind"]
EO = ["Flags", "ns::Flags"]

SELFTEST = [
    # (source, clang instances, expected)
    ("static_cast::<u32>(x)",            [_inst("NoOp", U32, U32)],                         "(x)"),
    ("static_cast::<u64>(n)",            [_inst("NoOp", USIZE, U64)],                       "(n as u64)"),
    ("static_cast::<u64>(a + b)",        [_inst("NoOp", U32, U64, ["IntegralCast"])],       "((a + b) as u64)"),
    ("static_cast::<u8>(x)",             [_inst("IntegralCast", U32, U8)],                  "(x as u8)"),
    ("static_cast::<u32>(self.kind)",    [_inst("IntegralCast", EK, U32)],                  "(self.kind as u8 as u32)"),
    ("static_cast::<u8>(k)",             [_inst("IntegralCast", EK, U8)],                   "(k as u8)"),
    ("static_cast::<Kind>(n)",           [_inst("IntegralCast", U32, EK)],                  "(n as u8 as Kind)"),
    ("static_cast::<Kind>(b)",           [_inst("IntegralCast", U8, EK)],                   "(b as Kind)"),
    ("static_cast::<Kind>(3)",           [_inst("IntegralCast", I32, EK)],                  "(3 as Kind)"),
    ("static_cast::<Flags>(n)",          [_inst("IntegralCast", U32, EO)],                  "(n as Flags)"),
    ("static_cast::<Flags>(w)",          [_inst("IntegralCast", U64, EO)],                  "(w as u32 as Flags)"),
    ("static_cast::<u8>(b)",             [_inst("IntegralCast", BOOL, U8)],                 "(b as u8)"),
    ("static_cast::<i32>(d)",            [_inst("FloatingToIntegral", F64, I32)],           "(d as i32)"),
    ("static_cast::<f64>(n)",            [_inst("IntegralToFloating", U64, F64)],           "(n as f64)"),
    ("static_cast::<bool>(n & 1)",       [_inst("IntegralToBoolean", U32, BOOL)],           "((n & 1) != 0)"),
    ("static_cast::<bool>(p)",           [_inst("PointerToBoolean", PB, BOOL)],             "((p) != &null)"),
    ("static_cast::<*B>(c)",             [_inst("NoOp", PC, PB, ["DerivedToBase"])],        "(unsafe (c as unsafe *B))"),
    ("static_cast::<*C>(b)",             [_inst("BaseToDerived", PB, PC)],                  "(unsafe (b as unsafe *C))"),
    ("static_cast::<*C>(v)",             [_inst("BitCast", PV, PC)],                        "(unsafe (v as unsafe *C))"),
    ("reinterpret_cast::<*u8>(p)",       [_inst("BitCast", PB, ["u8 *", "unsigned char *"])], "(unsafe (p as unsafe *u8))"),
    ("reinterpret_cast::<u64>(p)",       [_inst("PointerToIntegral", PB, U64)],             "(p as usize as u64)"),
    ("reinterpret_cast::<usize>(p)",     [_inst("PointerToIntegral", PB, USIZE)],           "(p as usize)"),
    ("reinterpret_cast::<u32>(p)",       [_inst("PointerToIntegral", PB, U32)],             None),
    ("reinterpret_cast::<*C>(n)",        [_inst("IntegralToPointer", USIZE, PC)],           "(unsafe (n as unsafe *C))"),
    ("const_cast::<*C>(p)",              [_inst("NoOp", ["const C *", "const ns::C *"], PC)], "(unsafe (p as unsafe *C))"),
    ("static_cast::<const *C>(p)",       [_inst("NoOp", PC, ["const C *", "const ns::C *"])], "(unsafe (p as unsafe *const C))"),
    ("static_cast::<char>(n)",           [_inst("IntegralCast", U32, CHAR)],                None),
    ("static_cast::<std::Legacy::char>(n)", [_inst("IntegralCast", U32, CHAR)],             None),
    ("static_cast::<u32>(x)",            [_inst("IntegralCast", U64, U32), _inst("NoOp", U32, U32)], None),
    ("static_cast::<T>(x)",              [_inst("Dependent", None, None)],                  None),
    ("static_cast::<u32>(-x)",           [_inst("IntegralCast", ["i32", "int"], U32)],      "((-x) as u32)"),
    ("static_cast::<u8>(a->b.c())",      [_inst("IntegralCast", U32, U8)],                  "(a->b.c() as u8)"),
    ("static_cast::<*C>(&null)",         [_inst("NullToPointer", ["std::nullptr_t", "std::nullptr_t"], PC)], "(unsafe (&null as unsafe *C))"),
    ("static_cast::<*C>(p + 1)",         [_inst("BitCast", PV, PC)],                        "(unsafe ((p + 1) as unsafe *C))"),
    ("static_cast<usize>(w)",            [_inst("IntegralCast", U32, USIZE)],               "(w as usize)"),
    ("static_cast::<u32>(-1)",           [_inst("IntegralCast", I32, U32)],                 "((-1) as i32 as u32)"),
    ("static_cast::<u64>(~0)",           [_inst("IntegralCast", I32, U64)],                 "((~0) as i32 as u64)"),
    ("static_cast::<u8>(300)",           [_inst("IntegralCast", I32, U8)],                  "(300 as i32 as u8)"),
    ("static_cast::<u8>(16)",            [_inst("IntegralCast", I32, U8)],                  "(16 as u8)"),
    ("static_cast::<u8>(static_cast::<u32>(k))",
                                         None,                                               "((k as u8 as u32) as u8)"),
]


def selftest():
    global _FACTS
    _FACTS = {"by_file": {}, "pointer_bits": 64,
              "enums": {"ns::Kind": {"name": "Kind"}, "ns::Flags": {"name": "Flags"}}}
    _ENUM_SRC["ns::Kind"] = ("u8", False)
    _ENUM_SRC["ns::Flags"] = ("u32", True)
    bad = 0
    for src, insts, want in SELFTEST:
        if insts is None:
            # nested: the inner enum cast, the outer int narrowing
            inner = {"kw": "static_cast", "inst": [_inst("IntegralCast", EK, U32)]}
            outer = {"kw": "static_cast", "inst": [_inst("IntegralCast", U32, U8)]}
            sites = [outer, inner]
        else:
            sites = [{"kw": re.match(r"\w+", src).group(0), "inst": insts}]
        ss = scan(src)
        for s, c in zip(ss, sites):
            c.update(written=s["target"], line=1)
        _FACTS["by_file"]["t.k"] = sites
        rep = []
        got, n = rewrite(src, "t.k", rep)
        got = got if n else None
        ok = got == want
        bad += not ok
        why = "" if got else (rep[0].split(": ", 1)[-1] if rep else "")
        print("%-4s %-44s -> %s %s" % ("ok" if ok else "FAIL", src, got, "" if ok else f"(want {want!r}) {rep}"))
    # order mismatch: two sites whose targets do not line up -> file skipped
    _FACTS["by_file"]["t.k"] = [{"kw": "static_cast", "written": "u64", "line": 1,
                                 "inst": [_inst("IntegralCast", U32, U64)]}]
    rep = []
    got, n = rewrite("static_cast::<u8>(x)", "t.k", rep)
    ok = n == 0 and "FILE SKIPPED" in rep[0]
    bad += not ok
    print("%-4s %-44s -> %s" % ("ok" if ok else "FAIL", "target mismatch skips the file", rep[0] if rep else ""))
    # a cast clang never saw (compiled-out branch), beside one it did: the
    # line pairing rewrites the seen one and reports the other.
    _FACTS["by_file"]["t.k"] = [{"kw": "static_cast", "written": "u8", "line": 2,
                                 "inst": [_inst("IntegralCast", U32, U8)]}]
    rep = []
    got, n = rewrite("static_cast::<u16>(a)\nstatic_cast::<u8>(x)", "t.k", rep)
    ok = n == 1 and got == "static_cast::<u16>(a)\n(x as u8)"
    bad += not ok
    print("%-4s %-44s -> %r %s" % ("ok" if ok else "FAIL", "compiled-out site reported, rest paired", got, rep))
    STATS.clear()
    REASONS.clear()
    print("\n%d case(s), %d failed" % (len(SELFTEST) + 2, bad))
    return 1 if bad else 0


atexit.register(summary)

if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    sys.exit(run(rewrite, "static_cast / reinterpret_cast / const_cast::<T>(x) -> Stage 1 `as`, by clang's cast kind"))
