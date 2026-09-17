#!/usr/bin/env python3
# __inline_cpp("(T)x")  ->  x as T        (Stage 0 -> Stage 1 corpus)
#
# 141 of the 222 __inline_cpp sites in Compiler/ are a C cast and nothing else,
# over EIGHT distinct target types. This is that rule. It does not translate
# C++; it recognises one shape, maps the type through a table, and emits the
# Kairo cast.
#
# Three things the table is not free to get wrong:
#
#   pointers   T* is *T, and the star count carries: T** -> **T.
#   unsafe     a cast to a pointer REQUIRES it. `f as *void` does not compile;
#              `f as unsafe *void` does. Scalars never take it.
#   refs       T& has no representable Stage 1 type. Never rewritten, always
#              reported.
#
# Float widths come from AST/Node/CanonicalNodes.k, which states the C++
# mapping per entry -- float/double/long double/__float128 are f32/f64/f80/f128,
# and f80 is x87 extended and x86-only (:242). `char` is deliberately absent:
# its signedness is implementation-defined and Kairo's `Char` is char32_t, so
# those sites are reported rather than guessed.
#
# Sites inside `inline "c++"` blocks are not touched -- those bodies are C++
# wholesale and a lone Kairo cast spliced into one is not valid C++. They are a
# separate rule.
#
#   python3 Scripts/Migration/inline_cpp_casts.py <corpus-root>
#   python3 Scripts/Migration/inline_cpp_casts.py <corpus-root> --apply
#   python3 Scripts/Migration/inline_cpp_casts.py --selftest
#
# Meant for a COPY of the tree: Compiler/ stays Stage 0 syntax because Stage 0
# compiles it. The corpus is the migrated copy.
import sys, os, re
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kairo_lex import code_mask, run

BASE = {
    # fixed width
    "uint8_t": "u8",   "uint16_t": "u16", "uint32_t": "u32", "uint64_t": "u64",
    "int8_t":  "i8",   "int16_t":  "i16", "int32_t":  "i32", "int64_t":  "i64",
    "__uint128_t": "u128", "unsigned __int128": "u128",
    "__int128_t":  "i128", "__int128": "i128", "signed __int128": "i128",
    # pointer width
    "size_t": "usize", "uintptr_t": "usize",
    "ptrdiff_t": "isize", "ssize_t": "isize", "intptr_t": "isize",
    # float -- CanonicalNodes.k states each C++ mapping
    "float": "f32", "double": "f64", "long double": "f80", "__float128": "f128",
    # plain C spellings
    "bool": "bool", "void": "void",
    "unsigned char": "u8",  "signed char": "i8",
    "short": "i16", "unsigned short": "u16", "short int": "i16",
    "int": "i32",   "unsigned": "u32", "unsigned int": "u32",
    "long": "i64",  "unsigned long": "u64",
    "long long": "i64", "unsigned long long": "u64",
    # already-Kairo spellings that appear in C cast position
    "u8": "u8", "u16": "u16", "u32": "u32", "u64": "u64", "u128": "u128",
    "i8": "i8", "i16": "i16", "i32": "i32", "i64": "i64", "i128": "i128",
    "usize": "usize", "isize": "isize",
    "f8": "f8", "f16": "f16", "f32": "f32", "f64": "f64",
    "f80": "f80", "f128": "f128",
}

# Reported, never mapped. Each needs a decision, not a table entry.
REFUSE = {
    "char":  "signedness is implementation-defined, and Kairo's Char is char32_t",
    "wchar_t": "width is platform-dependent (16 on Windows, 32 elsewhere)",
    "auto":  "not a type",
}

CALL = "__inline_cpp"
# The whole argument must be the cast: a leading (TYPE) and an operand, nothing
# after it. Anything with a trailing operator is a cast of an EXPRESSION and
# goes through the same path, parenthesised.
CAST = re.compile(r'^\(\s*([A-Za-z_][\w:<>\s*&]*?)\s*\)\s*(.+)$', re.S)
ATOMIC = re.compile(r'''[A-Za-z_]\w*|-?\d[\w.'+-]*|"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*\'''', re.X)


def unquote(lit):
    """Decode the Kairo string literal __inline_cpp was handed."""
    if lit.startswith('r"') and lit.endswith('"'):
        return lit[2:-1]
    if lit.startswith('"') and lit.endswith('"'):
        out, i, s = [], 1, lit[:-1]
        while i < len(s):
            if s[i] == "\\" and i + 1 < len(s):
                out.append({"n": "\n", "t": "\t", "r": "\r",
                            '"': '"', "\\": "\\"}.get(s[i + 1], s[i + 1]))
                i += 2
                continue
            out.append(s[i])
            i += 1
        return "".join(out)
    return None


def parse_ctype(t):
    """C type -> Kairo type. Returns (kairo, is_pointer) or (None, why)."""
    t = re.sub(r"\b(const|volatile|struct|class|typename)\b", " ", t)
    t = " ".join(t.split())
    if "&" in t:
        return None, "reference type -- no representable Stage 1 spelling"
    stars = 0
    while t.endswith("*"):
        stars += 1
        t = t[:-1].strip()
    if not t:
        return None, "empty base type"
    if t in REFUSE:
        return None, f"'{t}': {REFUSE[t]}"
    k = BASE.get(t)
    if k is None:
        return None, f"no mapping for base type '{t}'"
    # T* is *T, and the star count carries through: T** is **T.
    return ("*" * stars + k), (stars > 0)


def _group(op, i):
    """Index just past the balanced group opening at op[i], or -1."""
    close = {"(": ")", "[": "]", "{": "}"}[op[i]]
    depth = 0
    while i < len(op):
        if op[i] in "([{":
            depth += 1
        elif op[i] in ")]}":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return -1


def needs_parens(op):
    """False when op is a primary followed only by postfix, which all bind
    tighter than `as` -- so `x[i] as u8` and `a->b.c() as u64` are already
    unambiguous. True for anything with a binary operator at top level, which
    `as` would otherwise bind into: `(a + b) as u64`, never `a + b as u64`."""
    i = 0
    if i < len(op) and op[i] in "([":
        j = _group(op, i)
        if j < 0:
            return True
        i = j
    else:
        m = ATOMIC.match(op)
        if not m or m.start() != 0:
            return True
        i = m.end()
    while i < len(op):
        if op[i] in "([":
            j = _group(op, i)
            if j < 0:
                return True
            i = j
            continue
        m = re.match(r"(?:\.|->|::)\s*[A-Za-z_]\w*", op[i:])
        if m:
            i += m.end()
            continue
        return True          # a top-level operator: wrap it
    return False


def split_unary(op):
    """(unary-expression, tail).

    A C cast binds to a UNARY-expression, not to the rest of the line:
    `(T)a + b` is `((T)a) + b`, not `(T)(a + b)`. Taking everything after the
    close paren as the operand changes the value -- silently, and differently
    for signed and unsigned. So the operand is delimited here: optional prefix
    operators, one primary, then postfix."""
    i, n = 0, len(op)
    while i < n:
        m = re.match(r"\s*(\+\+|--|[-+!~*&])\s*", op[i:])
        if not m or m.end() == 0:
            break
        i += m.end()
    if i < n and op[i] in "([":
        j = _group(op, i)
        if j < 0:
            return None, None
        i = j
    else:
        m = ATOMIC.match(op[i:])
        if not m:
            return None, None
        i += m.end()
    while i < n:
        if op[i] in "([":
            j = _group(op, i)
            if j < 0:
                return None, None
            i = j
            continue
        m = re.match(r"(?:\.|->|::)\s*[A-Za-z_]\w*", op[i:])
        if m:
            i += m.end()
            continue
        m = re.match(r"\+\+|--", op[i:])
        if m:
            i += m.end()
            continue
        break
    return op[:i].strip(), op[i:].strip()


def render(operand, ktype, is_ptr):
    op, tail = split_unary(operand.strip().rstrip(";").strip())
    if op is None:
        return None
    if needs_parens(op):
        op = "(" + op + ")"
    # A cast to a pointer requires `unsafe`; a scalar cast never takes it.
    core = f"{op} as " + ("unsafe " if is_ptr else "") + ktype
    # Parenthesised when anything follows, so the result does not depend on
    # where `as` sits in Kairo's precedence table relative to that operator.
    return f"({core}) {tail}" if tail else core


def convert(arg_src):
    """Kairo-literal argument text -> (replacement, note) or (None, why)."""
    inner = unquote(arg_src.strip())
    if inner is None:
        return None, "argument is not a plain string literal"
    inner = inner.strip()
    if "\n" in inner:
        return None, "multi-line body, not a cast"
    m = CAST.match(inner)
    if not m:
        return None, "not a cast"
    ktype, info = parse_ctype(m.group(1))
    if ktype is None:
        return None, info
    operand = m.group(2).strip()
    if not operand:
        return None, "cast with no operand"
    note = None
    if ktype.endswith("f80"):
        note = "long double -> f80 is x87 extended, x86 only (CanonicalNodes.k:242)"
    if operand.startswith('"') and ktype.startswith("*"):
        note = "string literal cast to a pointer -- Kairo `string` is not const char*"
    out = render(operand, ktype, info)
    if out is None:
        return None, "could not delimit the cast operand"
    return out, note


def rewrite(src, path, report):
    mask = code_mask(src)
    hits = []
    for m in re.finditer(r"\b%s\s*\(" % CALL, src):
        if not all(mask[k] for k in range(m.start(), m.end())):
            continue
        depth, j = 1, m.end()
        while j < len(src) and depth:
            if src[j] == "(":
                depth += 1
            elif src[j] == ")":
                depth -= 1
            j += 1
        if depth:
            continue
        hits.append((m.start(), j, src[m.end():j - 1]))

    n = 0
    for start, end, arg in reversed(hits):
        rep, why = convert(arg)
        line = src[:start].count("\n") + 1
        if rep is None:
            one = " ".join(arg.split())[:60]
            report.append(f"{path}:{line}: {why}  --  {one}")
            continue
        if why:
            report.append(f"{path}:{line}: NOTE {why}")
        src = src[:start] + rep + src[end:]
        n += 1
    return src, n


SELFTEST = [
    ('"(uint64_t)0"',            "0 as u64"),
    ('"(size_t)5"',              "5 as usize"),
    ('"(uint8_t)16"',            "16 as u8"),
    ('"(double)1.0"',            "1.0 as f64"),
    ('"(long double)0.00001"',   "0.00001 as f80"),
    ('"(unsigned long)x"',       "x as u64"),
    ('"(u8*)v"',                 "v as unsafe *u8"),
    ('"(void*)p"',               "p as unsafe *void"),
    ('"(char**)argv"',           None),          # char: refused
    ('"(uint8_t**)p"',           "p as unsafe **u8"),
    ('"(const uint32_t*)p"',     "p as unsafe *u32"),
    ('"(uint64_t)(a + b)"',      "(a + b) as u64"),
    ('"(uint64_t)a + b"',        "(a as u64) + b"),
    ('"(size_t)(a) + (b)"',      "((a) as usize) + (b)"),
    ('"(uint8_t)x[i]"',          "x[i] as u8"),
    ('"(uint64_t)a->b.c()"',     "a->b.c() as u64"),
    ('"(size_t)v.size()"',       "v.size() as usize"),
    ('"(uint32_t)a * b"',        "(a as u32) * b"),
    ('"(u8*)buf + off"',         "(buf as unsafe *u8) + off"),
    ('"(uint64_t)-x"',           "(-x) as u64"),
    ('"(size_t)*p"',             "(*p) as usize"),
    ('"(uint64_t)a == b"',       "(a as u64) == b"),
    ('"(int&)r"',                None),          # reference: refused
    ('"::close(fd)"',            None),          # not a cast
]


def selftest():
    bad = 0
    for arg, want in SELFTEST:
        got, note = convert(arg)
        ok = (got == want)
        if not ok:
            bad += 1
        print("%-4s %-26s -> %-24s %s" % ("ok" if ok else "FAIL", arg,
                                          repr(got), note or ""))
    print("\n%d case(s), %d failed" % (len(SELFTEST), bad))
    return 1 if bad else 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    sys.exit(run(rewrite, '__inline_cpp("(T)x") -> x as T  (pointers: as unsafe *T)'))
