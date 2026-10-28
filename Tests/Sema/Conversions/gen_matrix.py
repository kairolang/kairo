#!/usr/bin/env python3
"""Generate the primitive conversion matrix tests in this directory.

The expected verdict for every ordered pair (S, T) of primitive types comes
from the SPEC (conversion-lattice.mdx, casting.mdx, primitives.mdx), coded
below as `classify` -- never from the compiler. A cell where the compiler
disagrees is a bug: it goes in KNOWN_BUGS, which routes that cell out of the
main files into an XFAIL file of its own whose header names the bug, so the
spec's verdict stays the assertion.

Usage:
    python3 Tests/Sema/Conversions/gen_matrix.py           # (re)write the files
    python3 Tests/Sema/Conversions/gen_matrix.py --check   # diff, write nothing
    python3 Tests/Sema/Conversions/gen_matrix.py --table   # the derived table, markdown

The lit wiring is generated too; run the files with llvm-lit as usual.

Files written (all generated; edit this script, not them):
    matrix_<S>.k        S as the source, every T in the base set as the target,
                        in every implicit context plus `as`. --type-check-only.
    matrix_wide_<W>.k   W in {f80, f128} against every type, both directions.
                        Pinned to x86_64 Linux, the one target set with both.
    roundtrip_as.k      every non-X `as` compiled, linked and run: 1 as T as S
                        is 1 again, for every pair. roundtrip_as_wide.k: the
                        pairs with an f80/f128 side, x86_64 Linux only.
    xfail_as_*.k        one per RT_BUGS entry: round trips the toolchain
                        cannot build today, held out under their ticket.

The hand-written run_*.k / xfail_*.k beside these check edge VALUES (min/max,
-1 to unsigned, rounding, saturation); this script owns only the files above.

The contexts, per pair (lattice section in parentheses):
    init     `var v: T = s`                 (W or I, else SC028E)
    assign   `v = s`                        (same)
    arg      `sink_T(s)`                    (same; SC063E + candidate note)
    ret      `return s` from `-> T`         (same)
    join     `if c => s else => t`          (unifies iff W one way only, s6; SC039E)
    eq       `s == t`                       (s6 unification; SC033E)
    add      `s + t`, numeric pairs         (s6; result is the W target)
    bitand   `s & t`, integer/byte pairs    (s6)
    shl      `s << t`, integer pairs        (s6: the count is unified apart)
    compound `v += s`, numeric pairs        (s6: needs W(S -> T) or exact)
    as       `s as T`                       (I/W/E allowed, X is SC027E)
"""

import argparse
import difflib
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

# --- the primitive set ------------------------------------------------------

class Ty:
    def __init__(self, name, cat, bits=0, signed=False, mant=0, ptr=False):
        self.name, self.cat, self.bits, self.signed = name, cat, bits, signed
        self.mant, self.ptr = mant, ptr

    @property
    def wide(self):
        # R5: anything past 64 bits. f80 is 80 bits, so it is extended too.
        return self.bits > 64

    def __repr__(self):
        return self.name

INTS = [Ty("i8", "int", 8, True), Ty("i16", "int", 16, True), Ty("i32", "int", 32, True),
        Ty("i64", "int", 64, True), Ty("i128", "int", 128, True), Ty("isize", "int", 64, True, ptr=True),
        Ty("u8", "int", 8), Ty("u16", "int", 16), Ty("u32", "int", 32),
        Ty("u64", "int", 64), Ty("u128", "int", 128), Ty("usize", "int", 64, ptr=True)]
FLOATS = [Ty("f16", "float", 16, mant=11), Ty("bf16", "float", 16, mant=8),
          Ty("f32", "float", 32, mant=24), Ty("f64", "float", 64, mant=53)]
WIDE_FLOATS = [Ty("f80", "float", 80), Ty("f128", "float", 128)]
OTHERS = [Ty("bool", "bool"), Ty("char", "char"), Ty("byte", "byte"), Ty("c_char", "c_char")]

BASE = INTS + FLOATS + OTHERS          # every target has these
ALL = INTS + FLOATS + WIDE_FLOATS + OTHERS
BY_NAME = {t.name: t for t in ALL}

# --- the spec, as rules -----------------------------------------------------

LAT = "conversion-lattice.mdx"

def classify(s, t):
    """(class, citation) for S -> T, from the spec alone."""
    if s is t:
        return "I", f"{LAT} s1: identity"
    si, ti = s.cat == "int", t.cat == "int"
    sf, tf = s.cat == "float", t.cat == "float"
    if si and ti:
        if s.ptr or t.ptr:
            return "E", f"{LAT} s4: usize/isize take no W to or from any type, each other included"
        if s.wide or t.wide:
            return "E", f"{LAT} R5: no type wider than 64 bits is a W source or target"
        if s.signed == t.signed:
            return ("W" if t.bits > s.bits else "E"), f"{LAT} R1: same-sign widening iff M > N"
        if not s.signed:
            return ("W" if t.bits > s.bits else "E"), f"{LAT} R2: uN -> iM iff M > N"
        return "E", f"{LAT} R2: iN -> uM is never W"
    if si and tf:
        if s.ptr:
            return "E", f"{LAT} s4: usize/isize take no W"
        if s.wide or t.wide:
            return "E", f"{LAT} R5: extended width is opaque"
        cite = f"{LAT} R3: W iff bits(S) <= mantissa(T) (f16 11, f32 24, f64 53)"
        if t.name == "bf16":
            cite = f"{LAT} R3 applied to bf16's 8-bit significand (decision: R3's table has no bf16 row)"
        return ("W" if s.bits <= t.mant else "E"), cite
    if sf and ti:
        return "E", f"{LAT} s3.1: float-to-int is E in all cases"
    if sf and tf:
        if s.wide or t.wide:
            return "E", f"{LAT} R5: extended width is opaque"
        if (s.name, t.name) in {("f16", "f32"), ("f16", "f64"), ("f32", "f64")}:
            return "W", f"{LAT} R4: f16 -> f32/f64, f32 -> f64"
        if s.name == "bf16" and t.name in ("f32", "f64"):
            return "W", "decision: bf16 -> f32/f64 is exact by construction; R4 names no bf16 pair (the compiler's W)"
        return "E", f"{LAT} R4: every other float pair is E"
    # One side is bool / char / byte / c_char.
    if s.cat == "c_char" or t.cat == "c_char":
        other = t if s.cat == "c_char" else s
        if other.cat == "int":
            return "E", "primitives.mdx c_char: `as` converts it to and from the integers"
        return "X", "decision: c_char is a character, not a number (primitives.mdx); X like char's row"
    nonnum = s if s.cat in ("bool", "char", "byte") else t
    other = t if nonnum is s else s
    if other.cat == "int":
        return "E", f"{LAT} s3.1/s4: {nonnum.name} <-> any int is E"
    return "X", f"{LAT} s3.1: bool, char and byte take no `as` to floats or to each other"

def W(s, t):
    return classify(s, t)[0] == "W"

def unify(a, b):
    """s6: the operand type of `a op b`, or None (an error)."""
    if a is b:
        return a
    ab, ba = W(a, b), W(b, a)
    if ab and not ba:
        return b
    if ba and not ab:
        return a
    return None

def numeric(t):
    return t.cat in ("int", "float")

# --- known compiler disagreements --------------------------------------------
# The type-checking matrix has none: every cell above agrees with the spec, so
# a red matrix_*.k is a regression, not a known bug. The run side has three.
# Each key is an `as` pair (S, T) that the spec allows (class E) but the
# toolchain cannot build; its round trip leaves roundtrip_as*.k for
# xfail_<file>.k, under a header naming the ticket, so the spec's verdict
# stays the assertion. When one XPASSes, delete its entry here and rerun:
# the pair moves back into the main file (delete the stale xfail file).

RT_BUGS = {
    "xfail_as_f16_bf16.k": (
        "clang",
        [("f16", "bf16"), ("bf16", "f16")],
        """\
Ticket "[Codegen] `f16 as bf16` / `bf16 as f16` emit a static_cast clang
refuses" (2026-10-28). Both are E (R4: every float pair but the three
widenings), so Sema accepts them, and EmitIR's _cast spells every numeric
`as` as static_cast<T>(x). clang has no direct _Float16 <-> __bf16
conversion: CL001E "static_cast from '_Float16' to '__bf16' is not
allowed". Going through float is exact on the way in (both widen to f32
without loss), so `static_cast<__bf16>(static_cast<float>(x))` rounds once.""",
    ),
    "xfail_as_f16_int128.k": (
        # The gap is this bundle's x86_64 compiler-rt; another host's archive
        # may have the routines and would XPASS.
        "clang, host-x86_64",
        [("f16", "i128"), ("i128", "f16"), ("f16", "u128"), ("u128", "f16")],
        """\
Ticket "[Toolchain] f16 <-> i128/u128 casts link against compiler-rt
builtins the bundle lacks" (2026-10-28). The casts are E (R5) and clang
lowers them to libcalls: L001E undefined symbol __fixhfti, __fixunshfti,
__floattihf, __floatuntihf. The staged compiler-rt builtins archive was
built without them. An XPASS on some host means its archive has them.""",
    ),
    "xfail_as_f80_bf16.k": (
        "clang, host-x86_64, host-linux",
        [("f80", "bf16")],
        """\
Ticket "[Toolchain] f80 -> bf16 links against __truncxfbf2, which the
bundle lacks" (2026-10-28). `x as bf16` on an f80 is E (R5); clang lowers
the long double -> __bf16 truncation to a libcall the staged compiler-rt
builtins do not define (L001E).""",
    ),
}

def _bugged():
    out = {}
    for fname, (_, pairs, _) in RT_BUGS.items():
        for s, t in pairs:
            out[(s, t)] = fname
    return out


# --- messages -----------------------------------------------------------------

def hint(s, t):
    c = classify(s, t)[0]
    if c == "E":
        return "; the conversion may lose value and needs an explicit 'as'"
    return ""

def conv_err(s, t):
    return ("SC028E", f"cannot convert '{s.name}' to '{t.name}'{hint(s, t)}", None)

def arg_err(s, t):
    return ("SC063E", f"no matching overload for call to 'sink_{t.name}'",
            f"candidate not viable: cannot convert argument of type '{s.name}' to parameter 'x' of type '{t.name}'")

def unify_err(a, b):
    return ("SC033E", f"operands '{a.name}' and '{b.name}' do not unify; neither converts implicitly to the other",
            "cast one side explicitly with 'as' to choose the result type")

def bitwise_mix_err(a, b):
    return ("SC067E", f"bitwise operators require two integers, two bytes, or two bools, not '{a.name}' and '{b.name}'", None)

def join_err(a, b):
    return ("SC039E", f"the 'else' branch has type '{b.name}', which does not unify with the earlier '{a.name}'",
            "every branch of a value-producing construct must convert to one type")

def as_err(s, t):
    return ("SC027E", f"no conversion from '{s.name}' to '{t.name}'",
            "these types have no meaningful representation change; use a library function")

# --- one pair's function --------------------------------------------------------

def pair_body(s, t):
    """[(code line, context, expected diag or None)] for S -> T."""
    out = []
    ok = classify(s, t)[0] in ("I", "W")
    def add(code, ctx, diag):
        out.append((code, ctx, diag))
    add(f"var v_init: {t.name} = s;", "init", None if ok else conv_err(s, t))
    add(f"var v_asg: {t.name} = t;", "-", None)
    add("v_asg = s;", "assign", None if ok else conv_err(s, t))
    add(f"sink_{t.name}(s);", "arg", None if ok else arg_err(s, t))
    if s is not t:
        u = unify(s, t)
        add("var v_join = if c => s else => t;", "join", None if u else join_err(s, t))
        add("var v_eq = s == t;", "eq", None if u else unify_err(s, t))
        if numeric(s) and numeric(t):
            add("var v_add = s + t;", "add", None if u else unify_err(s, t))
            if u is not None:
                # The result is the W target: it fits a slot of that type, and
                # does not fit one of the other side's type (that would be the
                # narrowing back, E).
                lo = s if u is t else t
                add(f"var v_add_hi: {u.name} = s + t;", "add-type", None)
                add(f"var v_add_lo: {lo.name} = s + t;", "add-type", conv_err(u, lo))
            add(f"var v_cmp: {t.name} = t;", "-", None)
            add("v_cmp += s;", "compound", None if ok else conv_err(s, t))
        intish = lambda x: x.cat == "int" or x.cat == "byte"
        if intish(s) and intish(t):
            # s6 lists `byte & u8` as an error without naming it; the operator
            # check refuses the mix before unification is asked (SC067E).
            err = bitwise_mix_err(s, t) if (s.cat == "byte") != (t.cat == "byte") else unify_err(s, t)
            add("var v_and = s & t;", "bitand", None if u else err)
        if s.cat == "int" and t.cat == "int":
            # Shift: the count is unified apart, any integer; the result is
            # the left operand's type.
            add(f"var v_shl: {s.name} = s << t;", "shl", None)
    else:
        if numeric(s):
            add("var v_add = s + t;", "add", None)
            add("v_asg += s;", "compound", None)
        add("var v_eq = s == t;", "eq", None)
    cls = classify(s, t)[0]
    add(f"var v_as = s as {t.name};", "as", as_err(s, t) if cls == "X" else None)
    add("return s;", "ret", None if ok else conv_err(s, t))
    return out

# --- file assembly ----------------------------------------------------------------

HEADER_COMMON = """\
// GENERATED by Tests/Sema/Conversions/gen_matrix.py -- do not edit; rerun it.
//
// The primitive conversion matrix: {what}.
// Every expected verdict is the SPEC's (conversion-lattice.mdx; casting.mdx;
// primitives.mdx for c_char and byte), derived by the generator's
// classify(), not read off the compiler.
// Each `S_to_T` function exercises one ordered pair in every context the
// lattice has a rule for: initialization, assignment, argument, return, the
// if-expression join and `==` (s6 unification), `+` with its result type,
// `&`, `<<` (the count unifies apart), `+=` and an explicit `as`. An error
// line is checked by its line, code and message; every other line is held
// clean by --implicit-check-not and a per-line NOT.
"""

def emit_file(pairs, what, extra_run="", requires=None, needed_sinks=None):
    lines = []
    lines += HEADER_COMMON.format(what=what).rstrip("\n").split("\n")
    lines.append("")
    lines.append("import std::c_char")
    lines.append("")
    sinks = needed_sinks or sorted({t.name for _, t in pairs}, key=lambda n: [x.name for x in ALL].index(n))
    for n in sinks:
        lines.append(f"fn sink_{n}(x: {n}) {{ }}")
    lines.append("")
    expect = []   # (line, ctx, diag or None)
    for s, t in pairs:
        lines.append(f"fn {s.name}_to_{t.name}(c: bool, s: {s.name}, t: {t.name}) -> {t.name} {{")
        for code, ctx, diag in pair_body(s, t):
            lines.append("    " + code)
            if ctx != "-":
                expect.append((len(lines), ctx, diag))
        lines.append("}")
        lines.append("")
    lines.append("fn main() -> i32 { return 0; }")
    lines.append("")
    lines.append("// --- lit wiring ---------------------------------------------------------")
    if requires:
        lines.append(f"// REQUIRES: {requires}")
    lines.append("// Lints are not the type relation (lattice s8): -A SC031W drops redundant-cast")
    lines.append("// on the identity `as`. --cmax-errors=0: every cell must report.")
    lines.append("// RUN: { %kairo %s --type-check-only --cmax-errors=0 -A SC031W" + extra_run + " 2>&1 || true; } \\")
    lines.append("// RUN:   | %FileCheck %s --check-prefix=DIAG --allow-empty \\")
    lines.append("// RUN:       --implicit-check-not='error [' --implicit-check-not='warning ['")
    for ln, ctx, diag in expect:
        if diag is None:
            lines.append(f"// DIAG-NOT: :{ln}:")
        else:
            code, msg, note = diag
            lines.append(f"// DIAG: {{{{.*}}}}:{ln}:{{{{[0-9]+}}}}: error [{code}]: {msg}")
            if note:
                lines.append(f"// DIAG-NEXT: {{{{.*}}}}: note [I900N]: {note}")
    return "\n".join(lines) + "\n"

def matrix_files():
    files = {}
    for s in BASE:
        pairs = [(s, t) for t in BASE]
        files[f"matrix_{s.name}.k"] = emit_file(pairs, f"source {s.name}, every base target")
    for w in WIDE_FLOATS:
        pairs = [(w, t) for t in ALL] + [(s, w) for s in ALL if s is not w]
        files[f"matrix_wide_{w.name}.k"] = emit_file(
            pairs, f"{w.name} against every type, both directions\n// (pinned to x86_64 Linux, which has both f80 and f128)",
            extra_run=" --target=x86_64-unknown-linux-gnu",
            requires="host-linux || sysroot-x86_64-linux-gnu",
            needed_sinks=[t.name for t in ALL])
    return files

# --- the run test: every allowed `as` round-trips 1 -------------------------------

def one_of(t):
    if t.cat == "bool":
        return "true"
    if t.cat in ("int", "float"):
        return f"1 as {t.name}"
    return f"1u8 as {t.name}"   # char, byte, c_char: `as` from an integer

def allowed_pairs(types):
    """Every (S, T) whose `as` both ways is not X, in table order."""
    return [(s, t) for s in types for t in types
            if classify(s, t)[0] != "X" and classify(t, s)[0] != "X"]

def roundtrip_file(pairs, what, requires, xfail_header=None):
    lines = []
    lines.append("// GENERATED by Tests/Sema/Conversions/gen_matrix.py -- do not edit; rerun it.")
    lines.append("//")
    lines.append(f"// Every `as` the spec allows between {what}, compiled, linked and run:")
    lines.append("// 1 as T as S is 1 again (true for bool), for every ordered pair whose")
    lines.append("// class is not X (conversion-lattice.mdx s1: I, W and E all take `as`).")
    lines.append("// 1 is exact in every type here, so a miss is a wrong conversion, and a")
    lines.append("// C++ error is a cast EmitIR spelled that clang refuses. A failing pair")
    lines.append("// prints its names; the exit code counts them. Each value comes out of")
    lines.append("// a call (one_S), so the casts are runtime conversions at -O0.")
    if xfail_header:
        lines.append("//")
        lines.append("// XFAIL: *")
        lines += ["// " + l if l else "//" for l in xfail_header.split("\n")]
    lines.append("")
    lines.append("import std::c_char")
    lines.append("import std::io::println")
    lines.append("")
    srcs = []
    for s, _ in pairs:
        if s not in srcs:
            srcs.append(s)
    for s in srcs:
        lines.append(f"fn one_{s.name}(k: i32) -> {s.name} {{ return {one_of(s)}; }}")
    lines.append("")
    lines.append("fn main() -> i32 {")
    lines.append("    var bad = 0;")
    for s in srcs:
        lines.append(f"    var x_{s.name} = one_{s.name}(0);")
    for s, t in pairs:
        lines.append(f"    if ((x_{s.name} as {t.name}) as {s.name}) != x_{s.name} {{ println(\"{s.name} -> {t.name}\"); bad += 1; }}")
    lines.append("    println(f\"checked {bad}\");")
    lines.append("    return bad;")
    lines.append("}")
    lines.append("")
    lines.append("// --- lit wiring ---------------------------------------------------------")
    lines.append(f"// {len(pairs)} pairs. -A SC031W: a lint, not the relation (lattice s8).")
    lines.append(f"// REQUIRES: {requires}")
    lines.append("// RUN: rm -rf %t.d")
    lines.append("// RUN: %kairo %s -A SC031W -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=BUILD --allow-empty")
    lines.append("// BUILD-NOT: {{error|warning}}")
    lines.append("// RUN: %t.exe > %t.out")
    lines.append("// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out")
    lines.append("// OUT: checked 0")
    return "\n".join(lines) + "\n"

def run_files():
    bugged = _bugged()
    keep = lambda ps: [(s, t) for s, t in ps if (s.name, t.name) not in bugged]
    wide_names = {w.name for w in WIDE_FLOATS}
    wide_pairs = [(s, t) for s, t in allowed_pairs(ALL) if s.name in wide_names or t.name in wide_names]
    files = {
        "roundtrip_as.k": roundtrip_file(keep(allowed_pairs(BASE)), "the base types", "clang"),
        "roundtrip_as_wide.k": roundtrip_file(keep(wide_pairs), "f80/f128 and every type",
                                              "clang, host-x86_64, host-linux"),
    }
    for fname, (requires, pairs, header) in RT_BUGS.items():
        ps = [(BY_NAME[s], BY_NAME[t]) for s, t in pairs]
        files[fname] = roundtrip_file(ps, ", ".join(f"{s.name} -> {t.name}" for s, t in ps),
                                      requires, xfail_header=header)
    return files


# --- the table ------------------------------------------------------------------

def table():
    out = []
    names = [t.name for t in ALL]
    out.append("| S \\ T | " + " | ".join(f"`{n}`" for n in names) + " |")
    out.append("|---|" + "---|" * len(names))
    for s in ALL:
        out.append(f"| **`{s.name}`** | " + " | ".join(classify(s, t)[0] for t in ALL) + " |")
    out.append("")
    out.append("Implicit: I and W. Explicit `as`: I, W and E; X is refused (SC027E).")
    out.append("")
    out.append("Citations (one per distinct rule):")
    out.append("")
    seen = {}
    for s in ALL:
        for t in ALL:
            c, why = classify(s, t)
            seen.setdefault(why, []).append(f"{s.name}->{t.name}")
    for why, cells in seen.items():
        sample = ", ".join(cells[:6]) + (f", ... ({len(cells)} cells)" if len(cells) > 6 else "")
        out.append(f"- {why}: {sample}")
    return "\n".join(out) + "\n"

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true", help="diff against the files on disk, write nothing")
    ap.add_argument("--table", action="store_true", help="print the derived class table as markdown")
    a = ap.parse_args()
    if a.table:
        sys.stdout.write(table())
        return 0
    files = {}
    files.update(matrix_files())
    files.update(run_files())
    stale = 0
    for name, text in sorted(files.items()):
        path = os.path.join(HERE, name)
        old = open(path, encoding="utf-8").read() if os.path.exists(path) else ""
        if old == text:
            continue
        stale += 1
        if a.check:
            sys.stdout.writelines(difflib.unified_diff(old.splitlines(True), text.splitlines(True), path, path + " (generated)"))
        else:
            with open(path, "w", encoding="utf-8", newline="\n") as f:
                f.write(text)
            print(f"wrote {name}")
    if a.check and stale:
        print(f"{stale} file(s) out of date")
        return 1
    return 0

if __name__ == "__main__":
    sys.exit(main())
