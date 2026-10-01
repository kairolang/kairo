#!/usr/bin/env python3
# Redundant parentheses -> gone, needed ones kept.
#
#     if (x > 0) {                 ->  if x > 0 {
#     while (i < n) {              ->  while i < n {
#     for (var i = 0; i < n; ++i) {->  for var i = 0; i < n; ++i {
#     x = (a * b) + c;             ->  x = a * b + c;
#     a + ((b - a) - c)            ->  a + (b - a - c)
#     a - (b - c)                  ->  unchanged (left-assoc: the pair is the tree)
#
# *** STAGE 0 SAFE BY DEFAULT ***
# Compiler/ is compiled by Stage 0, whose prefix operators swallow the WHOLE
# rest of their level: `!a && b` is `!(a && b)`, `-x == 0 && b` is
# `-(x == 0 && b)`, `*p += x` is `*(p += x)`, and -- measured with
# `kairo --emit-ir` on 2026-10-01, contradicting bad_pred_fix.py's docstring --
# `!(a) && b` is ALSO `!((a) && b)`: a paren right after the operator does not
# bound it. Only `(!a) && b` is safe. So by default this pass never removes a
# pair that would leave a prefix operator in front of a binary operator, `as`
# or a postfix step at the same level, never touches `op(...)` that is followed
# by more expression, and treats `as`, `^^` and `===` as unknown-precedence
# (Stage 0 rejects `x as u8 + 1` outright and reads `-x as u8` as
# `-(x as u8)`). --no-stage0-safe drops all of that and gives the pure Stage 1
# result (`if (!a == b) && c {` -> `if !a == b && c {`).
#
# Sites where the two compilers ALREADY disagree -- a prefix operator followed
# by a binary operator inside one level, `(!a == b)` -- are reported in both
# modes and, in safe mode, left exactly as they are. Removing nothing there
# does not fix them; it just refuses to bury them.
#
# How: every `(` `)` pair is a candidate. Pairs are decided outer-first, each
# against the CURRENT text (pairs already removed are transparent), so
# `((a + b)) * c` ends as `(a + b) * c`. A pair goes when
#   - its interior parses as one expression (a small Pratt parser over the
#     ExprParse.k table, nested brackets opaque), and
#   - the token on each side, classified as boundary / binary op / prefix op /
#     `as` / postfix step, cannot bind into the interior differently once the
#     parens are gone (precedence, then associativity).
# The test is local, which is sound here because every single removal is
# tree-preserving and they are applied one at a time.
#
# The table (ExprParse.k, Precedence) -- loosest to tightest:
#     = op=  (R)   ??  (R)   .. ..=  (non-assoc)   || or   && and   | bitor
#     ^ xor   & bitand   == != === not_eq   < > <= >= <=> in   << >>
#     + -   * / %   ^^ (R)   .* ->* ?.* ?->*   `as`   prefix   postfix
# Spec/Docs/operators.md disagrees with the parser about `<=>`, `in`, the `.*`
# family, range associativity and `??` (absent there). Those are UNCERTAIN: a
# pair whose fate depends on their precedence against another operator is
# kept in both modes; a plain operand next to them still loses its parens.
#
# Rule 1 -- statement heads: `if`, `else if`, `while`, `match`, `switch` and
# `for` lose a pair that wraps the ENTIRE head, i.e. whose `)` is followed by
# the body `{`. `for` only in its C-style form (two top-level `;`, starting
# with var/const) -- Stage 1 has no paren grammar there and Stage 0 accepts the
# bare form; `for (a, b) in xs` is a destructure and never touched. A head that
# is not braced (`if (c) stmt;`, a do-while `} while (c);`) is left alone.
# `if (a) && (b) {` is not wrapped as a whole, so rule 1 does not fire -- but
# both pairs hold a single operand, so the sub-pass below still yields
# `if a && b {`. That is intended.
#
# Never touched:
#   - call / index / generic argument lists, fn signatures and closure params
#     (anything right after an identifier, `)`, `]`, tight `>`, `fn`, `op`,
#     sizeof/typeof/alignof), tuples and `(x,)` (a comma never parses as one
#     expression), `({ ... })` statement expressions and any interior holding a
#     top-level `{` (parens reset NoStructLiteral; `(Foo) {` would become an
#     initializer), a pair followed by `(` (C-cast / call-on-paren shape), a
#     lone primitive `(u8)`, `(5).x` (would lex as a float);
#   - anything to the right of `case`, `fn`, `macro`, `import`, `requires`,
#     `where`, `catch`, `as`, a `:` not separated by `=` (types, named args,
#     map keys) ... see EXCLUDE_KW; macro bodies and `name!(...)` / `@attr(...)`
#     arguments (token substitution -- a paren there changes the expansion);
#   - interiors with `if`/`match`/`try`/`fn`/`else` (expression-if, Stage 0
#     ternary), `impl`/`derives`, or anything else the parser does not know:
#     the pair is kept (--log-bail lists them);
#   - comments, strings, char literals, inline "c++" bodies -- and f-string
#     interpolations, which are opaque here (kairo_lex treats them as code;
#     this pass does not, to keep the tokenizer honest);
#   - a pair spanning lines unless a surviving ( or [ still encloses it: at
#     statement level a newline ends the expression, inside the parens it did
#     not;
#   - removals that would glue two operator characters (`-(-a)` -> `--a`).
#
# Edits are paren characters only, plus the whitespace the paren held apart
# (`if ( x ) {` -> `if x {`); `if(x){` gets a space (`if x {`).
#
#     python3 Scripts/Migration/redundant_parens.py <root> [--apply] [--only S]
#             [--no-stage0-safe] [--log-bail]
#     python3 Scripts/Migration/redundant_parens.py --selftest
import sys, os, re
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kairo_lex import code_mask, run

CHAR_LIT = re.compile(r"'(?:\\(?:x[0-9A-Fa-f]{2}|u\{?[0-9A-Fa-f]+\}?|.)|[^'\\\n])'")
NUM = re.compile(r"0[xXbBoO][0-9A-Fa-f_]+\w*|\d[\d_]*(?:\.(?![.*])\d[\d_]*)?(?:[eE][+-]?\d+)?\w*")
TUPLE_IDX = re.compile(r"\d+")
IDENT_RE = re.compile(r"[A-Za-z_]\w*")
OPS = sorted("""
    ?->* ?.* ->* <<= >>= <=> === ... ..= ?-> ?. -> .* :: .. ^^ ?? ++ -- += -= *=
    /= %= &= |= ^= @= == != <= >= << >> && || ( ) [ ] { } < > + - * / % ^ | & ~
    ? ! @ = ; : , .
""".split(), key=len, reverse=True)

ASSIGN = {"=", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>="}
BIN = {op: (1, "R") for op in ASSIGN}
BIN.update({
    "??": (2, "R"),
    "..": (3, "N"), "..=": (3, "N"),
    "||": (4, "L"), "or": (4, "L"),
    "&&": (5, "L"), "and": (5, "L"),
    "|": (6, "L"), "bitor": (6, "L"),
    "^": (7, "L"), "xor": (7, "L"),
    "&": (8, "L"), "bitand": (8, "L"),
    "==": (9, "L"), "!=": (9, "L"), "===": (9, "L"), "not_eq": (9, "L"),
    "<": (10, "L"), ">": (10, "L"), "<=": (10, "L"), ">=": (10, "L"),
    "<=>": (10, "L"), "in": (10, "L"),
    "<<": (11, "L"), ">>": (11, "L"),
    "+": (12, "L"), "-": (12, "L"),
    "*": (13, "L"), "/": (13, "L"), "%": (13, "L"),
    "^^": (14, "R"),
    ".*": (15, "L"), "->*": (15, "L"), "?.*": (15, "L"), "?->*": (15, "L"),
})
BIN_KW = {"or", "and", "bitor", "xor", "bitand", "not_eq", "in"}
# Parser and Spec/Docs/operators.md disagree on these; see the header.
UNCERTAIN = {"??", "..", "..=", "<=>", "in", ".*", "->*", "?.*", "?->*"}
# ... and Stage 0's handling of these is unknown or measured-different.
UNCERTAIN_S0 = UNCERTAIN | {"^^", "===", "as"}

PREFIX_SYM = {"!", "+", "-", "~", "&", "*", "++", "--"}
PREFIX_KW = {"await", "spawn", "thread", "eval", "unsafe", "delete"}
# ExprParse: an infix op on the next line continues the expression unless it
# could also start a statement (`is_unary_operator`).
UNARY_CAPABLE = {"+", "-", "*", "&", "~", "!", "++", "--", "..", "...", "..="}
MEMBER = {".", "->", "?.", "?->"}
POSTFIX = MEMBER | {"::", "++", "--", "...", "?"}

KEYWORDS = set("""
    return break continue panic match case default catch try finally if else
    while for assert loop var const fn op class union enum type struct
    interface extend module test macro import override final ffi impl derives
    where requires pub priv prot eval unsafe static async inline atomic volatile
    virtual mutable self true false in as and and_eq bitand bitor compl not
    not_eq or or_eq xor xor_eq await thread spawn delete yield sizeof alignof
    typeof switch
""".split())
ATOM_KW = {"self", "true", "false", "null", "Self", "__file__", "__line__",
           "__column__", "__function__", "__module__"}
PRIMS = set("""
    i8 i16 i32 i64 i128 i256 i512 u8 u16 u32 u64 u128 u256 u512 f8 f16 f32 f64
    f80 f128 f256 f512 bf16 f8e4m3 f8e5m2 bool void usize isize byte char
""".split())
HEAD_KW = {"if", "while", "match", "switch", "for"}
STMT_KW = {"return", "yield", "var", "const", "static", "let", "panic",
           "assert", "break", "continue", "else", "loop", "try", "finally"}
# A pair to the right of one of these (same level, same statement) is grammar,
# not grouping: patterns, signatures, types, constraints.
EXCLUDE_KW = {"case", "default", "fn", "op", "macro", "import", "using", "type",
              "class", "struct", "enum", "union", "interface", "extend",
              "module", "requires", "impl", "derives", "where", "catch", "as",
              "ffi", "test", "override", "virtual", "inline", "pub", "priv",
              "prot"}
OPCHARS = set("+-*/%^|&~!<>=?.:@")


class Bail(Exception):
    pass


# --------------------------------------------------------------------------
# Tokens. Strings (whole f-strings included), comments and inline "c++"
# bodies come from kairo_lex's mask; char literals are matched here, since
# kairo_lex does not know them and `'('` would otherwise open a group.
# --------------------------------------------------------------------------
class Toks:
    def __init__(self, src):
        self.src = src
        self.kind, self.text, self.s, self.e, self.nl = [], [], [], [], []
        self._lex()

    def _add(self, kind, s, e, nl):
        self.kind.append(kind)
        self.text.append(self.src[s:e])
        self.s.append(s)
        self.e.append(e)
        self.nl.append(nl)

    def _string_end(self, i):
        src, n = self.src, len(self.src)
        is_f = src[i] == "f"
        if src[i] in "rf":
            i += 1
        i += 1
        while i < n:
            if src[i] == "\\":
                i += 2
                continue
            if src[i] == '"':
                return i + 1
            if is_f and src[i] == "{":
                depth = 0
                while i < n:
                    if src[i] == "{":
                        depth += 1
                    elif src[i] == "}":
                        depth -= 1
                        if depth == 0:
                            break
                    i += 1
            i += 1
        return n

    def _lex(self):
        src = self.src
        n = len(src)
        mask = code_mask(src)
        i, nl = 0, False
        while i < n:
            c = src[i]
            if not mask[i]:
                if src.startswith("//", i):
                    j = src.find("\n", i)
                    i = n if j < 0 else j
                    continue
                if src.startswith("/*", i):
                    j = src.find("*/", i + 2)
                    j = n if j < 0 else j + 2
                    nl = nl or "\n" in src[i:j]
                    i = j
                    continue
                if c == '"' or (c in "rf" and src[i + 1:i + 2] == '"'):
                    j = self._string_end(i)
                    self._add("str", i, j, nl)
                    nl = False
                    i = j
                    continue
                j = i
                while j < n and not mask[j]:
                    j += 1
                self._add("opaque", i, j, nl)  # inline "c++" body, or unknown
                nl = False
                i = j
                continue
            if c == "\n":
                nl = True
                i += 1
                continue
            if c.isspace():
                i += 1
                continue
            if c == "'":
                m = CHAR_LIT.match(src, i)
                j = m.end() if m else i + 1
                self._add("chr" if m else "opaque", i, j, nl)
            elif c.isalpha() or c == "_":
                m = IDENT_RE.match(src, i)
                j = m.end()
                self._add("id", i, j, nl)
            elif c.isdigit():
                after_dot = self.text and self.text[-1] in MEMBER
                m = (TUPLE_IDX if after_dot else NUM).match(src, i)
                j = m.end()
                self._add("num", i, j, nl)
            else:
                for op in OPS:
                    if src.startswith(op, i):
                        j = i + len(op)
                        kind = ("open" if op in "([{" and len(op) == 1 else
                                "close" if op in ")]}" and len(op) == 1 else "op")
                        self._add(kind, i, j, nl)
                        break
                else:
                    j = i + 1
                    self._add("opaque", i, j, nl)  # $ # \ ` ...
            nl = False
            i = j


# --------------------------------------------------------------------------
# Interior parser: ExprParse.k's Pratt loop over a token slice, nested
# brackets opaque. Answers only "what binds loosest at the top level of this
# slice" plus the flags the safety rules need.
# --------------------------------------------------------------------------
class Interior:
    def __init__(self, tk, idxs, match):
        self.tk, self.L, self.match = tk, idxs, match
        self.at = {t: p for p, t in enumerate(idxs)}
        self.pos = 0
        self.has_prefix = False   # a prefix operator anywhere at this level
        self.top_brace = False    # a `{` group at this level
        self.diverge = []         # prefix ops Stage 0 reads differently
        self._prefix_ends = []

    def peek(self, k=0):
        p = self.pos + k
        return self.L[p] if p < len(self.L) else None

    def tx(self, t):
        return None if t is None else self.tk.text[t]

    def kd(self, t):
        return None if t is None else self.tk.kind[t]

    def skip_group(self):
        t = self.peek()
        close = self.match[t]
        if close not in self.at:
            raise Bail("group")
        self.pos = self.at[close] + 1

    def tight(self, a, b):
        return self.tk.e[a] == self.tk.s[b]

    def parse(self):
        node = self.expr(0)
        if self.pos != len(self.L):
            raise Bail(f"unparsed `{self.tx(self.peek())}`")
        for u, end in self._prefix_ends:
            if end < len(self.L) and self.tx(self.L[end]) in BIN:
                self.diverge.append(u)
        return node

    def expr(self, minp):
        return self.climb(self.cast(), minp)

    def climb(self, lhs, minp):
        while True:
            t = self.peek()
            x = self.tx(t)
            if x in ("impl", "derives"):
                raise Bail("constraint")
            if x not in BIN or self.kd(t) not in ("op", "id"):
                return lhs
            p, a = BIN[x]
            if p <= minp:
                return lhs
            self.pos += 1
            if x in ("..", "..=") and self.peek() is None:
                lhs = ("bin", x)  # open range `a..`
                continue
            rhs = self.cast()
            self.climb(rhs, 3 if p == 3 else (p - 1 if a == "R" else p))
            lhs = ("bin", x)

    def cast(self):
        e = self.unary()
        while self.tx(self.peek()) == "as":
            self.pos += 1
            if self.tx(self.peek()) == "var":
                raise Bail("as var")
            self.type_()
            if self.tx(self.peek()) == "{":
                raise Bail("as ... {")
            e = ("cast", None)
        return e

    def type_(self):
        while self.tx(self.peek()) in ("unsafe", "const", "static", "volatile",
                                       "*", "&", "?"):
            self.pos += 1
        t = self.peek()
        if self.kd(t) == "id" and (self.tx(t) not in KEYWORDS or self.tx(t) == "Self"):
            self.pos += 1
            while True:
                x = self.tx(self.peek())
                if x == "::":
                    self.pos += 1
                    if self.tx(self.peek()) == "<":
                        self.generic()
                    elif self.kd(self.peek()) == "id":
                        self.pos += 1
                    else:
                        raise Bail("type path")
                elif x == "<" and self.tight(self.L[self.pos - 1], self.peek()):
                    self.generic()
                else:
                    break
        elif self.tx(t) in ("(", "["):
            self.skip_group()
        else:
            raise Bail("type")
        # `x as T * 2`, `x as T[...]`: whether the type parser eats it is not
        # something to guess.
        if self.tx(self.peek()) in ("*", "&", "?", "[", "(", "<", "::", "{"):
            raise Bail("type suffix")

    def generic(self):
        """`<...>` after a path; `>>` closes two. Bails unless it is plainly a
        type/value argument list."""
        depth = 0
        while True:
            t = self.peek()
            x = self.tx(t)
            if t is None:
                raise Bail("generic")
            if x == "<":
                depth += 1
            elif x in (">", ">>"):
                depth -= 1 if x == ">" else 2
                if depth < 0:
                    raise Bail("generic")
                if depth == 0:
                    self.pos += 1
                    return
            elif x in ("(", "["):
                self.skip_group()
                continue
            elif self.kd(t) in ("id", "num") or x in ("::", ",", "*", "&", "?", "...", "."):
                pass
            else:
                raise Bail("generic")
            self.pos += 1

    def unary(self):
        t = self.peek()
        x = self.tx(t)
        if t is None:
            raise Bail("empty operand")
        if x == "&" and self.tx(self.peek(1)) == "null":
            self.pos += 2
            return self.post_loop(("primary", "null"), False)
        if self.kd(t) == "op" and x in PREFIX_SYM:
            self.pos += 1
            self.unary()
            self.has_prefix = True
            self._prefix_ends.append((t, self.pos))
            return ("prefix", x)
        if self.kd(t) == "id" and x in PREFIX_KW:
            self.pos += 1
            if x == "delete" and self.tx(self.peek()) == "[":
                self.skip_group()
            self.unary()
            self.has_prefix = True
            return ("prefix", x)
        if x in ("sizeof", "alignof", "typeof"):
            self.pos += 1
            if self.tx(self.peek()) != "(":
                raise Bail(x)
            self.skip_group()
            return ("primary", x)
        return self.postfix()

    def postfix(self):
        t = self.peek()
        x, k = self.tx(t), self.kd(t)
        path = False
        if k == "id":
            if x in KEYWORDS and x not in ATOM_KW:
                raise Bail(f"keyword `{x}`")
            self.pos += 1
            path = True
            base = ("primary", "prim" if x in PRIMS else "id")
        elif k in ("num", "str", "chr"):
            self.pos += 1
            base = ("primary", k)
        elif x in ("(", "["):
            self.skip_group()
            base = ("primary", "group")
        elif x == "{":
            self.skip_group()
            self.top_brace = True
            base = ("primary", "brace")
        elif x == "::" and self.kd(self.peek(1)) == "id":
            self.pos += 2
            path = True
            base = ("primary", "id")
        else:
            raise Bail(f"primary `{x}`")
        return self.post_loop(base, path)

    def post_loop(self, base, path):
        while True:
            t = self.peek()
            x, k = self.tx(t), self.kd(t)
            if t is None:
                return base
            if x in MEMBER:
                self.pos += 1
                n = self.peek()
                if self.kd(n) in ("id", "num"):
                    self.pos += 1
                elif self.tx(n) == "~" and self.kd(self.peek(1)) == "id":
                    self.pos += 2
                else:
                    raise Bail("member")
            elif x == "::":
                self.pos += 1
                if self.tx(self.peek()) == "<":
                    self.generic()
                elif self.kd(self.peek()) == "id":
                    self.pos += 1
                else:
                    raise Bail("::")
            elif x == "<" and path and self.tight(self.L[self.pos - 1], t):
                # `Foo<T>(...)` vs `a<b`: the real parser asks the symbol
                # table. Accept only a clean generic group followed by
                # something a generic name is followed by; otherwise bail.
                self.generic()
                if self.tx(self.peek()) not in (None, "(", "::", "{", "."):
                    raise Bail("generic or comparison")
            elif x == "(" or x == "[":
                self.skip_group()
                path = False
            elif x == "{":
                if not path:
                    return base
                self.skip_group()
                self.top_brace = True
                path = False
            elif k == "op" and x in ("++", "--", "...", "?"):
                self.pos += 1
                path = False
            else:
                return base
            base = ("primary", "chain")


# --------------------------------------------------------------------------
# The pass
# --------------------------------------------------------------------------
LEVEL = {"primary": 100, "prefix": 50, "cast": 40}


class Pass:
    def __init__(self, src, safe, path, report, log_bail):
        self.src, self.safe, self.path = src, safe, path
        self.report, self.log_bail = report, log_bail
        self.tk = tk = Toks(src)
        self.n = len(tk.kind)
        self.removed = set()
        self.space = set()      # removed parens replaced by one space
        self.headers = self.subs = self.bails = 0
        self.match = {}
        self.parent = {}
        stack = []
        for i, k in enumerate(tk.kind):
            if k == "open":
                self.parent[i] = stack[-1] if stack else None
                stack.append(i)
            elif k == "close":
                if not stack or "([{".index(tk.text[stack[-1]]) != ")]}".index(tk.text[i]):
                    raise Bail("unbalanced brackets")
                o = stack.pop()
                self.match[o], self.match[i] = i, o
        if stack:
            raise Bail("unbalanced brackets")
        self.frozen = self._frozen()
        self._unc = UNCERTAIN_S0 if safe else UNCERTAIN

    # -- helpers ------------------------------------------------------------
    def x(self, t):
        return None if t is None else self.tk.text[t]

    def k(self, t):
        return None if t is None else self.tk.kind[t]

    def line(self, t):
        return self.src.count("\n", 0, self.tk.s[t]) + 1

    def prev(self, t):
        t -= 1
        while t >= 0 and t in self.removed:
            t -= 1
        return t if t >= 0 else None

    def next(self, t):
        t += 1
        while t < self.n and t in self.removed:
            t += 1
        return t if t < self.n else None

    def tight(self, a, b):
        """Nothing but removed paren characters between tokens a and b."""
        gap = self.src[self.tk.e[a]:self.tk.s[b]]
        return all(c in "()" for c in gap)

    def _frozen(self):
        tk, fz = self.tk, set()
        for i in range(self.n):
            x = tk.text[i]
            # macro definitions: everything through the body
            if tk.kind[i] == "id" and x == "macro":
                j = i
                while j < self.n and tk.text[j] not in ("{", ";"):
                    j += 1
                if j < self.n and tk.text[j] == "{":
                    fz.update(range(i, self.match[j] + 1))
            # name!(...) invocations and @attr(...): token substitution
            if (x == "!" and i > 0 and tk.kind[i - 1] == "id"
                    and tk.text[i - 1] not in KEYWORDS
                    and tk.e[i - 1] == tk.s[i] and i + 1 < self.n
                    and tk.kind[i + 1] == "open"):
                fz.update(range(i + 1, self.match[i + 1] + 1))
            if (x == "@" and i + 2 < self.n and tk.kind[i + 1] == "id"
                    and tk.text[i + 2] == "("):
                fz.update(range(i + 2, self.match[i + 2] + 1))
        return fz

    def enclosing(self, o):
        p = self.parent.get(o)
        while p is not None and p in self.removed:
            p = self.parent.get(p)
        return p

    def nl_sensitive(self, o):
        p = self.enclosing(o)
        return p is None or self.x(p) == "{"

    def operand_end(self, j, k):
        """Is token j (left of op k) the end of an operand? None = can't say."""
        if j is None:
            return False
        kd, x = self.k(j), self.x(j)
        if kd == "id":
            return x not in KEYWORDS or x in ATOM_KW
        if kd in ("num", "str", "chr"):
            return True
        if x in (")", "]"):
            return True
        if x == "}":
            return not self.tk.nl[k]
        if x == "?":
            return True
        if x in ("++", "--", ">", ">>"):
            return None
        return False

    def is_ternary_if(self, t):
        # `foo()` newline `if (c) {` is a statement in a newline-terminated
        # file; a Stage 0 ternary never starts a line (ternary_to_if).
        if self.tk.nl[t]:
            return False
        p = self.prev(t)
        return bool(self.operand_end(p, t)) and self.x(p) not in ("else",)

    # -- context ------------------------------------------------------------
    def scan_left(self, o):
        """(excluded, head_kw, head_tok) for the statement/level holding o."""
        sens = self.nl_sensitive(o)
        k, after, seen_eq, angles = self.prev(o), o, False, 0
        while k is not None:
            kd, x = self.k(k), self.x(k)
            # inside `::<...>` / `Foo<...>` the pair is in a type or a value
            # generic argument -- `map::<K, *(Buf::<512>)>()` -- never touched
            if x in (">", ">>"):
                angles += 1 if x == ">" else 2
            elif x == "<":
                p = self.prev(k)
                if angles:
                    angles -= 1
                elif p is not None and (self.x(p) == "::" or
                                        (self.k(p) == "id" and self.tight(p, k))):
                    return True, None, None
            if (sens and self.tk.nl[after] and self.operand_end(k, after)
                    and not (self.x(after) in BIN and self.x(after) not in UNARY_CAPABLE)
                    and self.x(after) not in MEMBER):
                return False, None, None   # previous statement
            if kd == "close":
                if x == "}":
                    return False, None, None
                after, k = self.match[k], self.prev(self.match[k])
                continue
            if kd == "open" or x == ";":
                return False, None, None
            if kd == "opaque":
                return False, None, None   # an inline "c++" block ended a statement
            if x == "@":
                return True, None, None
            if kd == "id":
                if x in EXCLUDE_KW:
                    return True, None, None
                if x in HEAD_KW:
                    if x == "if" and self.is_ternary_if(k):
                        return True, None, None
                    return False, x, k
                if x in STMT_KW:
                    return False, None, None
            if x in ASSIGN:
                seen_eq = True
            if x == ":" and not seen_eq:
                return True, None, None
            after, k = k, self.prev(k)
        return False, None, None

    def head_ends_in_brace(self, c):
        sens = self.nl_sensitive(self.match[c])
        k, before = self.next(c), c
        while k is not None:
            kd, x = self.k(k), self.x(k)
            if (sens and self.tk.nl[k] and self.operand_end(before, k)
                    and not (x in BIN and x not in UNARY_CAPABLE) and x not in MEMBER):
                return False
            if x == "{":
                return True
            if kd == "close" or x == ";" or x in ("if", "else"):
                return False
            if x in ("(", "["):
                before, k = self.match[k], self.next(self.match[k])
                continue
            before, k = k, self.next(k)
        return False

    def classify_left(self, o):
        k = self.prev(o)
        if k is None:
            return ("bound",)
        kd, x = self.k(k), self.x(k)
        if kd == "open":
            return ("bound",)
        if kd == "close":
            return ("bound",) if x == "}" and self.tk.nl[o] else ("keep",)
        if x in (",", ";"):
            return ("bound",)
        if kd == "op":
            if x in (">", ">>") and self.tight(k, o):
                return ("keep",)            # Foo<T>(...)
            if x == "<":
                p = self.prev(k)
                if p is not None and (self.k(p) == "id" or self.x(p) == "::") and self.tight(p, k):
                    return ("keep",)        # Foo<(...)>
            if x in BIN and x not in PREFIX_SYM and x not in ("..", "..="):
                return ("bin", x)
            is_bin = self.operand_end(self.prev(k), k)
            if is_bin is None:
                return ("keep",)
            if is_bin and x in BIN:
                return ("bin", x)
            if not is_bin and x in PREFIX_SYM:
                return ("prefix", x)
            return ("keep",)                # name!(...), prefix range, `:`, `->` ...
        if kd == "id":
            if x in BIN_KW:
                return ("bin", x) if self.operand_end(self.prev(k), k) else ("keep",)
            if x in ("return", "yield"):
                return ("bound",)
            if x in HEAD_KW:
                return ("head", x, k)
            if x in PREFIX_KW:
                return ("prefix", x)
        return ("keep",)

    def classify_right(self, c):
        k = self.next(c)
        if k is None:
            return ("bound",)
        kd, x = self.k(k), self.x(k)
        if self.tk.nl[k] and self.nl_sensitive(self.match[c]):
            if x in MEMBER:
                return ("post", x)
            if x in BIN and x not in UNARY_CAPABLE and kd in ("op", "id"):
                return ("bin", x)
            return ("bound",)
        if kd == "close" or x in (",", ";"):
            return ("bound",)
        if x == "{":
            return ("brace",)
        if kd == "op":
            if x in BIN:
                return ("bin", x)
            if x in POSTFIX:
                return ("post", x)
            return ("keep",)
        if x == "[":
            return ("post", x)
        if kd == "id":
            if x == "as":
                return ("cast",)
            if x in BIN_KW:
                return ("bin", x)
        return ("keep",)

    # -- precedence ---------------------------------------------------------
    def certain(self, a, b):
        if a in self._unc or b in self._unc:
            if self.safe or a == b:
                return False
            # assignment is the loosest level in parser and spec alike, except
            # against `in`, which the spec puts below it
            return ((a in ASSIGN and b != "in") or (b in ASSIGN and a != "in"))
        return True

    def fits_left(self, L, node):
        kind, op = node
        if L[0] == "bound":
            return True
        if L[0] == "prefix":
            return kind in ("primary", "prefix")
        o = L[1]
        if kind == "primary":
            return True
        if kind == "prefix":
            return o not in self._unc
        if kind == "cast":
            return o not in self._unc and "as" not in self._unc
        p, a = BIN[o]
        q = BIN[op][0]
        return self.certain(o, op) and (q > p or (q == p and a == "R"))

    def fits_right(self, R, node):
        kind, op = node
        if R[0] == "bound":
            return True
        if R[0] == "post":
            return kind == "primary"
        if R[0] == "cast":
            return kind in ("primary", "prefix") or (kind == "cast" and "as" not in self._unc)
        o = R[1]
        if kind == "primary":
            return True
        if kind == "prefix":
            return o not in self._unc
        if kind == "cast":
            # `x as usize < n`: the type parser takes `<` as generic args
            # (found by type-checking the tree, Lib/builtin/fmt.k:64)
            if o.startswith("<"):
                return False
            return o not in self._unc and "as" not in self._unc
        p, a = BIN[o]
        q = BIN[op][0]
        return self.certain(op, o) and (q > p or (q == p and a == "L"))

    # -- one pair -----------------------------------------------------------
    def bail(self, o, why):
        self.bails += 1
        if self.log_bail:
            self.report.append(f"{self.path}:{self.line(o)}: kept, {why}")

    def diverge(self, o, what):
        self.report.append(
            f"{self.path}:{self.line(o)}: STAGE 0 DIVERGES -- {what}; "
            + ("left as is" if self.safe else "Stage 1 reading kept"))

    def snippet(self, a, b):
        return " ".join(self.src[self.tk.s[a]:self.tk.e[b]].split())[:70]

    def decide(self, o):
        c = self.match[o]
        if o in self.frozen:
            return None
        inner = [t for t in range(o + 1, c) if t not in self.removed]
        if not inner:
            return None
        L = self.classify_left(o)
        if L[0] == "keep":
            return None
        R = self.classify_right(c)
        if R[0] == "keep":
            return None
        excluded, head, _ = self.scan_left(o)
        if excluded:
            return None

        header = False
        if L[0] == "head":
            if L[1] == "if" and self.is_ternary_if(L[2]):
                return None
            if not self.head_ends_in_brace(c):
                return None
            if L[1] == "for" and R[0] != "brace":
                return None
            header = R[0] == "brace"
            L = ("bound",)
        elif L == ("bin", "in") and head == "for":
            L = ("bound",)
        if R[0] == "brace":
            if head is None and not header:
                return None
            R = ("bound",)

        if any(self.tk.nl[t] for t in range(o + 1, c + 1)):
            p = self.enclosing(o)
            if p is None or self.x(p) not in ("(", "["):
                return None
        if any(self.k(t) == "opaque" for t in inner):
            return None

        # C-style for: the head is three clauses, not an expression
        top = self.top_level(inner)
        if header and head == "for":
            semis = [t for t in top if self.x(t) == ";"]
            if (len(semis) != 2 or self.x(inner[0]) not in ("var", "const")
                    or any(self.x(t) == "{" for t in top)):
                return None
            return self.glue_ok(o, c, inner) and ("header",)
        if head == "for" and any(self.x(t) == ";" for t in top):
            return None

        try:
            ip = Interior(self.tk, inner, self.match)
            node = ip.parse()
        except Bail as b:
            self.bail(o, str(b))
            return None

        for u in ip.diverge:
            self.diverge(o, f"prefix `{self.x(u)}` in `({self.snippet(inner[0], inner[-1])})` "
                            "swallows the binary operator after its operand")
        if self.safe and ip.diverge:
            return None
        if ip.top_brace:
            return None
        if node == ("primary", "prim") and len(inner) == 1:
            return None
        if R[0] == "post" and len(inner) == 1 and self.k(inner[0]) == "num":
            return None
        if not (self.fits_left(L, node) and self.fits_right(R, node)):
            return None

        if self.safe:
            # A1: a prefix op that the parens bound would swallow what follows
            if ip.has_prefix and R[0] != "bound":
                return None
            # A2: `!(a) && b` -- Stage 0 already reads !((a) && b). A postfix
            # step binds inside the operand in both compilers, so `&(a).b`
            # is not one.
            if L[0] == "prefix" and R[0] in ("bin", "cast"):
                self.diverge(o, f"`{L[1]}({self.snippet(inner[0], inner[-1])})` is followed "
                                f"by `{self.x(self.next(c))}`; Stage 0 swallows it")
                return None
        if not self.glue_ok(o, c, inner):
            return None
        return ("header",) if header else ("sub",)

    def top_level(self, inner):
        """Tokens of `inner` not nested in a surviving bracket inside it."""
        out, at, p = [], {t: i for i, t in enumerate(inner)}, 0
        while p < len(inner):
            t = inner[p]
            out.append(t)
            p = at[self.match[t]] + 1 if self.k(t) == "open" else p + 1
        return out

    def glue_ok(self, o, c, inner):
        a, b = self.prev(o), self.next(c)
        first, last = inner[0], inner[-1]
        word = lambda ch: ch.isalnum() or ch in "_\"'"
        if a is not None and self.tight(a, o) and self.tight(o, first):
            ca, cf = self.tk.text[a][-1], self.tk.text[first][0]
            if ca in OPCHARS and cf in OPCHARS:
                return False
            if word(ca):
                self.space.add(o)       # if(x) -> if x, return(x) -> return x
        if b is not None and self.tight(c, b) and self.tight(last, c):
            cl, cb = self.tk.text[last][-1], self.tk.text[b][0]
            if cl in OPCHARS and cb in OPCHARS:
                return False
            if word(cb) or cb == "{":
                self.space.add(c)       # (x){ -> x {
        return True

    # -- driver -------------------------------------------------------------
    def run(self):
        for o in range(self.n):
            if self.x(o) != "(" or self.k(o) != "open":
                continue
            verdict = self.decide(o)
            if not verdict:
                self.space.discard(o)
                self.space.discard(self.match[o])
                continue
            self.removed.update((o, self.match[o]))
            if verdict[0] == "header":
                self.headers += 1
            else:
                self.subs += 1
        return self.render()

    def render(self):
        src, tk = self.src, self.tk
        drop = {}   # char offset -> replacement
        for t in self.removed:
            drop[tk.s[t]] = " " if t in self.space else ""
        out = []
        i, n = 0, len(src)
        while i < n:
            if i not in drop:
                out.append(src[i])
                i += 1
                continue
            rep = drop[i]
            ch = src[i]
            before = out[-1] if out else "\n"
            if ch == "(":
                j = i + 1
                while j < n and src[j] in " \t" and j not in drop:
                    j += 1
                # `if ( x` -> `if x`: the paren's inner padding goes with it
                if j > i + 1 and (before in " \t\n([{" or rep):
                    i = j
                else:
                    i += 1
                if rep and before not in " \t\n":
                    out.append(rep)
                continue
            # `)`: drop padding before it when nothing needs separating after
            after = src[i + 1] if i + 1 < n else "\n"
            if after in " \t\n)]},;" or rep:
                while out and out[-1] in (" ", "\t") and len(out) > 0:
                    out.pop()
            if rep and after not in " \t\n":
                out.append(rep)
            i += 1
        return "".join(out)


def rewrite(src, path, report, safe=None, log_bail=None):
    if safe is None:
        safe = "--no-stage0-safe" not in sys.argv
    if log_bail is None:
        log_bail = "--log-bail" in sys.argv
    if "(" not in src:
        return src, 0
    try:
        p = Pass(src, safe, path, report, log_bail)
    except Bail as b:
        report.append(f"{path}: SKIPPED ({b})")
        return src, 0
    out = p.run()
    if p.bails and not log_bail:
        report.append(f"{path}: {p.bails} pair(s) kept unparsed (--log-bail lists them)")
    return out, p.headers + p.subs


# --------------------------------------------------------------------------
# Self test: (source, want in safe mode, want with --no-stage0-safe).
# `None` for the second means "same as safe".
# --------------------------------------------------------------------------
SELFTEST = [
    # rule 1: statement heads
    ("if (x > 0) {", "if x > 0 {", None),
    ("if a {\n} else if (x > 0) {", "if a {\n} else if x > 0 {", None),
    ("while (i < n) {", "while i < n {", None),
    ("match (k) {", "match k {", None),
    ("switch (k) {", "switch k {", None),
    ("for (var i = 0; i < n; ++i) {", "for var i = 0; i < n; ++i {", None),
    ("for (a, b) in xs {", "for (a, b) in xs {", None),
    ("for x in (0..n) {", "for x in 0..n {", None),
    ("if(x){", "if x {", None),
    ("if ( x ) {", "if x {", None),
    ("if (x) return;", "if (x) return;", None),
    ("} while (x);", "} while (x);", None),
    ("var v = if (c) { a } else { b };", "var v = if c { a } else { b };", None),
    ("var p = f(x)\nif (p >= 0) && (q) {", "var p = f(x)\nif p >= 0 && q {", None),
    ("if (a == Foo{1}) {", "if (a == Foo{1}) {", None),
    ("if (a) && (b) {", "if a && b {", None),
    ("if (a &&\n    b) {", "if (a &&\n    b) {", None),
    ("if (x) {\n    y = (a);\n}", "if x {\n    y = a;\n}", None),
    # sub-pass: precedence and associativity
    ("x = a + ((b - a) - c);", "x = a + (b - a - c);", None),
    ("x = a - (b - c);", "x = a - (b - c);", None),
    ("x = (a - b) - c;", "x = a - b - c;", None),
    ("x = (a * b) + c;", "x = a * b + c;", None),
    ("x = (a + b) * c;", "x = (a + b) * c;", None),
    ("x = ((a + b)) * c;", "x = (a + b) * c;", None),
    ("x = (a == b) && (c < d);", "x = a == b && c < d;", None),
    ("x = (a & b) == c;", "x = (a & b) == c;", None),
    ("x = (a << 1) + b;", "x = (a << 1) + b;", None),
    ("x = (a + 1) << b;", "x = a + 1 << b;", None),
    ("x = a ^^ (b ^^ c);", "x = a ^^ (b ^^ c);", "x = a ^^ b ^^ c;"),
    ("x = (a ^^ b) ^^ c;", "x = (a ^^ b) ^^ c;", None),
    ("x = (a = b);", "x = a = b;", None),
    ("x = (a ?? b) || c;", "x = (a ?? b) || c;", None),
    ("x = (a ?? b);", "x = (a ?? b);", "x = a ?? b;"),
    ("x = (a..b);", "x = (a..b);", "x = a..b;"),
    ("x = (a < b) == (c in d);", "x = a < b == (c in d);", None),
    ("return (x);", "return x;", None),
    ("return(x);", "return x;", None),
    ("return (a + b) * c;", "return (a + b) * c;", None),
    ("foo((a + b));", "foo(a + b);", None),
    ("foo((a), (b));", "foo(a, b);", None),
    ("x = (a.b).c;", "x = a.b.c;", None),
    ("x = (foo(1))[2];", "x = foo(1)[2];", None),
    ("x = (5).x;", "x = (5).x;", None),
    # unary: the Stage 0 cases
    ("if (!a) && b {", "if (!a) && b {", "if !a && b {"),
    ("if (*p) += x;", "if (*p) += x;", None),
    ("(*p) += x;", "(*p) += x;", "*p += x;"),
    ("x = (-a) == 0;", "x = (-a) == 0;", "x = -a == 0;"),
    ("if (!a == b) && c {", "if (!a == b) && c {", "if !a == b && c {"),
    ("x = (a && !b) || c;", "x = (a && !b) || c;", "x = a && !b || c;"),
    ("x = a && (!b);", "x = a && !b;", None),
    ("if !(a) {", "if !a {", None),
    ("x = !(a) && b;", "x = !(a) && b;", "x = !a && b;"),
    ("x = -(a + b);", "x = -(a + b);", None),
    ("x = -(a.b);", "x = -a.b;", None),
    ("x = -(-a);", "x = -(-a);", None),
    ("x = a -(-b);", "x = a -(-b);", None),
    ("x = (&a).b;", "x = (&a).b;", None),
    ("x = &(a).b;", "x = &a.b;", None),
    ("x = &((f()).y);", "x = &f().y;", None),
    ("var m = map::<K, *(Buf::<512>)>();", "var m = map::<K, *(Buf::<512>)>();", None),
    ("x = a < (b) && c > (d);", "x = a < b && c > d;", None),
    ("x = &(a);", "x = &a;", None),
    ("x = (&null);", "x = &null;", None),
    # casts
    ("x = (y as u8) + 1;", "x = (y as u8) + 1;", "x = y as u8 + 1;"),
    ("x = (-y) as u8;", "x = (-y) as u8;", "x = -y as u8;"),
    ("x = -(y as u8);", "x = -(y as u8);", None),
    ("x = (y + 1) as u8;", "x = (y + 1) as u8;", None),
    ("x = (y as usize) < n;", "x = (y as usize) < n;", None),
    ("x = (y as usize) > n;", "x = (y as usize) > n;", "x = y as usize > n;"),
    ("foo((y as u8));", "foo(y as u8);", None),
    ("x = (u8)(y);", "x = (u8)(y);", None),
    # grammar parens: never
    ("var t = (a, b);", "var t = (a, b);", None),
    ("var t = (a,);", "var t = (a,);", None),
    ("var v = ({ a; b });", "var v = ({ a; b });", None),
    ("var v = (({ a; b }));", "var v = ({ a; b });", None),
    ("fn f(a: i32) -> (A) {", "fn f(a: i32) -> (A) {", None),
    ("var f = fn (x) { return (x); };", "var f = fn (x) { return x; };", None),
    ("foo(x: (a + b));", "foo(x: (a + b));", None),
    ("var x: T = (a);", "var x: T = a;", None),
    ("case (A) {", "case (A) {", None),
    ("x = ref!((a + b));", "x = ref!((a + b));", None),
    ("macro SQ!(x) { (x) * (x) }", "macro SQ!(x) { (x) * (x) }", None),
    ("x = foo::<T>((a));", "x = foo::<T>(a);", None),
    ("x = Foo<(N)>::v;", "x = Foo<(N)>::v;", None),
    ("x = Vec<Map<K, V>>::make((a)) + (b);", "x = Vec<Map<K, V>>::make(a) + b;", None),
    ("x = (Foo<T>::make(1)).y;", "x = Foo<T>::make(1).y;", None),
    ("x = (a < b) && c > (d);", "x = a < b && c > d;", None),
    ("x = (if c { a } else { b }) + 1;", "x = (if c { a } else { b }) + 1;", None),
    ("x = (a if c else b) + 1;", "x = (a if c else b) + 1;", None),
    ("x = (Foo{a: 1}).a;", "x = (Foo{a: 1}).a;", None),
    # strings, comments, chars
    ('s = "(a)" + (b);', 's = "(a)" + b;', None),
    ("x = (a) + 1; // (b)", "x = a + 1; // (b)", None),
    ("x = '(' == (c);", "x = '(' == c;", None),
    ('s = f"{(a + b)}";', 's = f"{(a + b)}";', None),
    ('inline "c++" { if (x) { y = (a); } }', 'inline "c++" { if (x) { y = (a); } }', None),
    # newlines
    ("x = (a +\n    b);", "x = (a +\n    b);", None),
    ("foo((a +\n    b));", "foo(a +\n    b);", None),
    ("x = (a)\n-b;", "x = a\n-b;", None),
]


def selftest():
    bad = 0
    for src, want_safe, want_raw in SELFTEST:
        # a head snippet (`if (x) {`) is closed so the bracket check passes
        tail = "\n" + "}" * (src.count("{") - src.count("}"))
        for safe, want in ((True, want_safe), (False, want_raw or want_safe)):
            got, _ = rewrite(src + tail, "t", [], safe=safe, log_bail=False)
            again, _ = rewrite(got, "t", [], safe=safe, log_bail=False)
            got, again = got[:len(got) - len(tail)], again[:len(again) - len(tail)]
            ok = got == want and again == got
            bad += 0 if ok else 1
            tag = "safe" if safe else "raw "
            if not ok:
                print(f"FAIL {tag} {src!r}\n       want {want!r}\n       got  {got!r}"
                      + ("" if again == got else f"\n       2nd  {again!r}"))
    total = 2 * len(SELFTEST)
    print(f"{total - bad}/{total} passed (each case in both modes, each re-run for idempotence)")
    return 1 if bad else 0


BANNER = """\
redundant_parens.py -- drop parentheses the Stage 1 grammar does not need.

  STAGE 0 SAFE BY DEFAULT. Compiler/ is compiled by Stage 0, whose prefix
  operators swallow the rest of their level (`!a && b` is `!(a && b)`, and so
  is `!(a) && b`). By default no removal leaves a prefix operator in front of
  a binary operator, `as` or a postfix step, and `as`, `^^`, `===` are
  treated as unknown precedence. --no-stage0-safe gives the pure Stage 1
  result; only use it on a tree Stage 0 will never compile.

usage: redundant_parens.py <root> [--apply] [--only SUBSTR]
                           [--no-stage0-safe] [--log-bail]
       redundant_parens.py --selftest
"""

if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    if len(sys.argv) < 2 or any(a in ("-h", "--help") for a in sys.argv[1:]):
        print(BANNER)
        sys.exit(0 if len(sys.argv) >= 2 else 2)
    sys.exit(run(rewrite, "redundant parentheses -> removed ("
                 + ("STAGE 0 SAFE" if "--no-stage0-safe" not in sys.argv
                    else "--no-stage0-safe: pure Stage 1 precedence") + ")"))
