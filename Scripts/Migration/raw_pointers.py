#!/usr/bin/env python3
# *T  ->  unsafe *T   in TYPE positions          (Stage 0 -> Stage 1 corpus)
#
# For self-hosting every Stage 0 pointer becomes a raw pointer: Stage 0's
# `*T` is C++'s `T*` with no rules attached, and Stage 1's safe `*T` carries
# Tether's. Whether a given pointer can later be made safe is a per-site
# decision for after the tree builds; `unsafe *T` is the spelling that means
# what the Stage 0 source already does.
#
# The hard part is not the rewrite but WHERE: `*` is also deref and multiply.
# Only a type is rewritten, and a type is found only where one must start:
#
#   name: T         after `var` / `let` / `const` / `static` / `eval` (any
#                   modifier run before them) and `for [var] x:`, and inside
#                   the parentheses of a `fn` signature or `fn(...)` type
#   ) -> T          a return type
#   ::<T, U>        a turbofish argument list, which is types or values
#   as T            Stage 0's own `as` cast
#   type X = T      an alias
#
# From such a start a small type grammar is walked -- prefixes `*`, `&`,
# `const`, `unsafe *`; a path with `<...>` / `::<...>` arguments; `[T; N]`,
# `(A, B)`, `fn(A) -> R`, a `?` suffix -- and each pointer prefix in it is
# rewritten, nested ones included (`vec<*T>`, `**T`, `fn(*A) -> *B`).
#
#   *T          -> unsafe *T
#   *const T    -> unsafe *const T
#   const *T    -> unsafe *const T     Stage 0 `const *T` is C++ `const T*`
#                                      (AST/Node/Casting.k: `const *Expr`
#                                      emits `const Expr *`); in Stage 1 the
#                                      constness of the pointee goes after
#                                      the `*`
#   **T         -> unsafe *unsafe *T
#   unsafe *T   unchanged (idempotent)
#
# A `name:` that is not one of the declaration contexts above -- a `case X:`
# label, a named argument -- is left alone and, when a `*` follows it,
# counted under --log so nothing is silently missed.
#
#   python3 Scripts/Migration/raw_pointers.py <corpus-root> [--apply] [--log]
#   python3 Scripts/Migration/raw_pointers.py --selftest
import os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kairo_lex import code_mask, run

ID = re.compile(r"[A-Za-z_]\w*")
WS = re.compile(r"\s*")
DECL_KW = re.compile(r"(?:\b(?:var|let|const|static|eval)\s+(?:(?:var|let|const|static|eval|mut)\s+)*)$")
FN_HEAD = re.compile(r"\bfn\b[^(){};]*$")
REF_MACRO = re.compile(r"(?:ref!|mref!?)\s*\(")


class TypeWalk:
    def __init__(self, src, mask):
        self.s, self.m, self.edits = src, mask, []

    def ws(self, i):
        while i < len(self.s) and self.s[i] in " \t\r\n" and self.m[i]:
            i += 1
        return i

    def kw(self, i, w):
        s = self.s
        return (s.startswith(w, i) and (i + len(w) >= len(s) or not (s[i + len(w)].isalnum() or s[i + len(w)] == "_"))
                and (i == 0 or not (s[i - 1].isalnum() or s[i - 1] == "_")))

    def typ(self, i, depth=0):
        """Walk one type from i; return its end (or i if none starts here)."""
        s = self.s
        if depth > 40:
            return i
        i = self.ws(i)
        if i >= len(s) or not self.m[i]:
            return i
        # unsafe *  -- already raw
        if self.kw(i, "unsafe"):
            j = self.ws(i + 6)
            if j < len(s) and s[j] == "*":
                k = self.ws(j + 1)
                if self.kw(k, "const"):
                    k = self.ws(k + 5)
                return self.typ(k, depth + 1)
            return i
        # const *T  -> unsafe *const T
        if self.kw(i, "const"):
            j = self.ws(i + 5)
            if j < len(s) and s[j] == "*":
                self.edits.append((i, j + 1, "unsafe *const "))
                k = self.ws(j + 1)
                if self.kw(k, "const"):      # `const *const T`: one const is enough
                    k = self.ws(k + 5)
                return self.typ(k, depth + 1)
            return self.typ(j, depth + 1)
        if s[i] == "*":
            self.edits.append((i, i, "unsafe "))
            k = self.ws(i + 1)
            if self.kw(k, "const"):
                k = self.ws(k + 5)
            return self.typ(k, depth + 1)
        if s[i] == "&":
            return self.typ(i + 1, depth + 1)
        if s[i] == "[":
            j = self.typ(i + 1, depth + 1)
            return self._close(j, "[", "]", i)
        if s[i] == "(":
            j = i + 1
            while True:
                j = self.typ(j, depth + 1)
                j = self.ws(j)
                if j < len(s) and s[j] == ",":
                    j += 1
                    continue
                break
            return self._close(j, "(", ")", i)
        if self.kw(i, "fn"):
            j = self.ws(i + 2)
            if j < len(s) and s[j] == "(":
                j = self.typ(j, depth + 1)   # the parameter list walks as a tuple
                k = self.ws(j)
                if s.startswith("->", k):
                    j = self.typ(k + 2, depth + 1)
                return self._suffix(j)
            return i
        # Stage 0's reference macros wrap a type: `ret: ref!(*Type)`. Walk
        # the inside, or ref_and_mref (a later pass) unwraps it to
        # `@inout ret: *Type` and a second run rewrites that -- the pipeline
        # would not be idempotent.
        rm = REF_MACRO.match(s, i)
        if rm and (i == 0 or not (s[i - 1].isalnum() or s[i - 1] == "_")):
            j = self.typ(rm.end(), depth + 1)
            return self._close(j, "(", ")", rm.end() - 1)
        m = ID.match(s, i)
        if not m:
            return i
        j = m.end()
        while True:
            k = self.ws(j)
            if s.startswith("::<", k):
                j = self.args(k + 3, depth)
                continue
            if s.startswith("::", k):
                m = ID.match(s, self.ws(k + 2))
                if not m:
                    break
                j = m.end()
                continue
            if k < len(s) and s[k] == "<" and self.m[k]:
                j = self.args(k + 1, depth)
                continue
            break
        return self._suffix(j)

    def _suffix(self, j):
        k = self.ws(j)
        while k < len(self.s) and self.s[k] == "?":
            j = k + 1
            k = self.ws(j)
        return j

    def _close(self, j, op, cl, start):
        """Skip to the bracket closing the one at start; values ride along."""
        depth, k = 0, start
        s = self.s
        while k < len(s):
            if self.m[k]:
                if s[k] in "([{<" and not (s[k] == "<" and k > 0 and s[k - 1] == "-"):
                    depth += 1
                elif s[k] in ")]}>" and not (s[k] == ">" and k > 0 and s[k - 1] == "-"):
                    depth -= 1
                    if depth == 0:
                        return k + 1
            k += 1
        return len(s)

    def args(self, i, depth):
        """A `<...>` list from just past the `<`: each argument that starts as
        a type is walked; a value (`4`, `N + 1`) is skipped."""
        s = self.s
        j = i
        while j < len(s):
            j = self.ws(j)
            e = self.typ(j, depth + 1)
            # skip whatever is left of this argument (a value expression)
            d = 0
            k = e
            while k < len(s):
                c = s[k]
                if not self.m[k]:
                    k += 1
                    continue
                if c in "([{":
                    d += 1
                elif c in ")]}":
                    d -= 1
                elif c == "<" and not s.startswith("<<", k):
                    d += 1
                elif c == ">" and not (k > 0 and s[k - 1] == "-"):
                    if d == 0:
                        return k + 1
                    d -= 1
                elif c == "," and d == 0:
                    break
                k += 1
            if k >= len(s):
                return len(s)
            j = k + 1
        return len(s)


def starts(src, mask):
    """Every offset where a type begins, and the `name: *` sites skipped."""
    out, skipped = [], []
    n = len(src)
    for m in re.finditer(r"(?<![:\w])([A-Za-z_]\w*)\s*:(?!:)", src):
        p = m.end()
        if not mask[m.start()] or not mask[p - 1]:
            continue
        before = src[:m.start(1)]
        line_start = before.rfind("\n") + 1
        head = before[line_start:].lstrip()
        if re.match(r"(case|default)\b", head):
            continue
        ok = False
        if DECL_KW.search(before[-200:]) or re.search(r"\bfor\s+(?:var\s+)?$", before[-40:]):
            ok = True
        else:
            # inside the parentheses of a fn signature / fn type
            d, k = 0, m.start(1) - 1
            while k >= 0 and k > m.start(1) - 4000:
                c = src[k]
                if mask[k]:
                    if c in ")]}":
                        d += 1
                    elif c in "([{":
                        if d == 0:
                            break
                        d -= 1
                k -= 1
            if k >= 0 and src[k] == "(":
                if FN_HEAD.search(src[max(0, k - 300):k]):
                    ok = True
        if ok:
            out.append(p)
        else:
            q = p
            while q < n and src[q] in " \t":
                q += 1
            if q < n and (src[q] == "*" or src.startswith("const *", q)):
                skipped.append(m.start(1))
    for m in re.finditer(r"\)\s*->", src):
        if mask[m.end() - 1]:
            out.append(m.end())
    for m in re.finditer(r"::<", src):
        if mask[m.start()]:
            out.append(("args", m.end()))
    for m in re.finditer(r"\bas\b", src):
        if mask[m.start()] and all(mask[k] for k in range(m.start(), m.end())):
            out.append(m.end())
    for m in re.finditer(r"\btype\s+[A-Za-z_]\w*\s*(?:<[^=;{}]*>)?\s*=", src):
        if mask[m.start()]:
            out.append(m.end())
    return out, skipped


def convert(src):
    mask = code_mask(src)
    w = TypeWalk(src, mask)
    sts, skipped = starts(src, mask)
    for st in sts:
        if isinstance(st, tuple):
            w.args(st[1], 0)
        else:
            w.typ(st)
    edits = sorted(set(w.edits))
    out, last = [], 0
    for a, b, t in edits:
        if a < last:
            continue
        out.append(src[last:a])
        out.append(t)
        last = b
    out.append(src[last:])
    return "".join(out), len(edits), skipped


def rewrite(src, path, report):
    new, n, skipped = convert(src)
    if "--log" in sys.argv:
        for off in skipped:
            line = src[:off].count("\n") + 1
            one = src[off:src.find("\n", off)].strip()[:70]
            report.append(f"{path}:{line}: `name: *` outside a declaration, left as is  --  {one}")
    elif skipped:
        report.append(f"{path}: {len(skipped)} `name: *` site(s) outside a declaration left as is (--log lists them)")
    return new, n


SELFTEST = [
    ("var x: *T = &null;",                 "var x: unsafe *T = &null;"),
    ("fn f(a: *A, b: **B) -> *C {",        "fn f(a: unsafe *A, b: unsafe *unsafe *B) -> unsafe *C {"),
    ("var v: vec::<*Decl>;",               "var v: vec::<unsafe *Decl>;"),
    ("var m: llvm::DenseMap<*A, vec<*B>>;", "var m: llvm::DenseMap<unsafe *A, vec<unsafe *B>>;"),
    ("x = static_cast::<*Expr>(p);",       "x = static_cast::<unsafe *Expr>(p);"),
    ("x = static_cast::<const *T>(p);",    "x = static_cast::<unsafe *const T>(p);"),
    ("fn g(p: const *Expr) -> const *T {", "fn g(p: unsafe *const Expr) -> unsafe *const T {"),
    ("var q: *const u8;",                  "var q: unsafe *const u8;"),
    ("var q: unsafe *u8;",                 "var q: unsafe *u8;"),
    ("y = *p * 2;",                        "y = *p * 2;"),
    ("*p = 3;",                            "*p = 3;"),
    ("case Kind::A: *p = 1;",              "case Kind::A: *p = 1;"),
    ("var f: fn(*A) -> *B;",               "var f: fn(unsafe *A) -> unsafe *B;"),
    ("var a: [*T; 4];",                    "var a: [unsafe *T; 4];"),
    ("var t: (*A, i32);",                  "var t: (unsafe *A, i32);"),
    ("var n: *T?;",                        "var n: unsafe *T?;"),
    ("pub static var g: *Foo = &null;",    "pub static var g: unsafe *Foo = &null;"),
    ("for var x: *T in xs {",              "for var x: unsafe *T in xs {"),
    ("var s = \"a: *b\"; // c: *d",       "var s = \"a: *b\"; // c: *d"),
    ("z = f::<N * 2>(a);",                 "z = f::<N * 2>(a);"),
    ("w = foo(a: *p);",                    "w = foo(a: *p);"),
    ("type P = *Node;",                    "type P = unsafe *Node;"),
    ("var x = y as *u8;",                  "var x = y as unsafe *u8;"),
    ("fn <T> h(self, p: *T) -> bool {",    "fn <T> h(self, p: unsafe *T) -> bool {"),
    ("fn d(ret: ref!(*Type), x: i32) {",   "fn d(ret: ref!(unsafe *Type), x: i32) {"),
    ("fn e(v: mref!(vec<*T>)) {",          "fn e(v: mref!(vec<unsafe *T>)) {"),
    ("fn r(self) -> ref!(*Node) {",        "fn r(self) -> ref!(unsafe *Node) {"),
    ("var x = pref!(*p);",                 "var x = pref!(*p);"),
]


def selftest():
    bad = 0
    for src, want in SELFTEST:
        got, _, _ = convert(src)
        ok = got == want
        bad += not ok
        print("%-4s %-40s -> %s" % ("ok" if ok else "FAIL", src, got if ok else f"{got!r}  (want {want!r})"))
    once, _, _ = convert(SELFTEST[1][1])
    if once != SELFTEST[1][1]:
        bad += 1
        print("FAIL not idempotent:", once)
    print("\n%d case(s), %d failed" % (len(SELFTEST), bad))
    return 1 if bad else 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    sys.exit(run(rewrite, "*T -> unsafe *T in type positions"))
