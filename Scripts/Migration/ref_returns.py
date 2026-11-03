#!/usr/bin/env python3
# Reference returns and by-reference range-for -> the pointer form.
#
#   fn first(self, ...) -> ref!(DiagBuilder) { ...; return self }
#       -> fn first(self, ...) -> *Self { ...; return &self }
#   fn invocation(self) -> ref!(CompilerInvocation) { return self._inv; }
#       -> fn invocation(self) -> unsafe *CompilerInvocation { return unsafe &self._inv; }
#   for var slot: ref!(Slot) in xs { slot.lexer = &null }
#       -> for *slot in xs { slot->lexer = &null }
#
# Stage 1 has no reference return type; ref_and_mref used to turn a
# `-> ref!(C)` inside C into `-> Self`, which COPIES: every builder chain
# then labelled a temporary and `report(...).first(r).emit()` emitted a copy
# while the original was dropped un-emitted. The user's answer (2026-11-03):
# the pointer form. A pointer is no place, so the call sites change too, and
# since migrate.py is per file, the methods whose call sites change are the
# CALLS table below (kept from the defs on 2026-11-03; a def this pass sees
# that the table does not name is reported). At a call site of a table
# method:
#
#   - followed by a member access `.m` -> `->m` (Spec/Docs pointers, "Member
#     access": `.` on a pointer is R027E). For a builder (a chain method that
#     returns its receiver) only when `m` is a method of the same chain, so
#     a same-named method of another type (`map.insert(k).first`) is left;
#   - a builder call as a statement (the chain's result dropped) -> as is;
#   - `return f()` inside a table method (a pointer returning a pointer)
#     -> as is;
#   - any other use is the referenced VALUE (an argument, an assignment
#     target, an initializer that C++'s `auto` copied) -> `*f()`.
#   - `&f()` is reported (it was already the pointer; drop the `&` by hand).
#
# `op =` is not rewritten: Stage 1 generates assignment from the transfer
# constructor and an explicit `op =` is an error (Spec/Docs
# classes-lifecycle), which is a different fix; those sites are reported and
# ref_and_mref keeps its old `-> Self` for them.
#
# A method of a class deriving a C++ base (clang::, llvm::, cxx::, libcxx::)
# must keep the C++ signature it overrides: it becomes `-> __builtin_cxx_lvalue_ref<T>`
# (the compiler spells it `T&`; that builtin does not exist yet, 2026-11-03)
# with `// TODO(CXX-REF): matches <base>::<method>`, and is reported. There
# were none on 2026-11-03.
#
# Runs before ref_and_mref (which would otherwise see the ref!) and after
# drop_turbofish / ranged_for_binding (so `define<T>(` and `for var x:`).
#
#     python3 Scripts/Migration/ref_returns.py <copy-of-tree> [--apply]
#     python3 Scripts/Migration/ref_returns.py --selftest
import os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kairo_lex import code_mask, run

DIAG = {"first", "second", "highlight", "strike", "fix", "remove", "insert", "_add_child",
        "_add_child_no_loc", "note", "warning", "remark", "verbose", "debug_note",
        "child_first", "child_second", "child_fix"}
CMD = {"define", "define_cfg"}
PROBE = {"cwd", "add_include", "add_includes", "extensions"}

# name -> (kind, chain names a following `.m` must be in (builders), files the
#          call sites are in (None: any), receiver text to skip)
CALLS = {}
for _n in DIAG:
    CALLS[_n] = ("builder", DIAG | {"emit"}, None, None)
for _n in CMD:
    CALLS[_n] = ("builder", CMD, None, None)
for _n in PROBE:
    CALLS[_n] = ("builder", PROBE | {"create_ptr"}, None, None)
CALLS["invocation"] = ("accessor", None, None, re.compile(r"(^|[^\w])_?be$"))  # ClangBackend's is a clang pointer
CALLS["as_list"] = ("accessor", None, None, None)
CALLS["get_list"] = ("accessor", None, None, None)
for _n in ("get_exprs", "get_holes", "get_prefix", "get_suffix", "get_body", "get_next", "get_prefix_kind"):
    # TextImm's; the AST string nodes have by-value methods of the same names
    CALLS[_n] = ("accessor", None, ("Compiler/Lexer/Lexer.k",), None)

CHARLIT = re.compile(r"r?'(?:\\x[0-9A-Fa-f]{1,8}|\\.|[^'\\\n])'")
RETREF = re.compile(r"->\s*ref!\(")
FORREF = re.compile(r"\bfor[ \t]+(?:var[ \t]+)?([A-Za-z_]\w*)[ \t]*:[ \t]*ref!\(")
# Stage 0 writes a generic class both ways: `class Name<T>` and `class <T> Name`
TYPEHEAD = re.compile(r"\b(?:class|struct)\s+(?:<[^{;]*?>\s*)?([A-Za-z_]\w*)\s*(<[^{;]*?>)?([^{;]*)\{")
IDCH = re.compile(r"[A-Za-z0-9_]")


def full_mask(src):
    """code_mask with char literals blanked too, so `'('` is no bracket."""
    mask = code_mask(src)
    for m in CHARLIT.finditer(src):
        if mask[m.start()] and (m.start() == 0 or not IDCH.match(src[m.start() - 1])):
            for k in range(m.start(), m.end()):
                mask[k] = False
    return mask


def fwd(src, mask, i, op, cl):
    depth = 0
    while i < len(src):
        if mask[i]:
            if src[i] == op:
                depth += 1
            elif src[i] == cl:
                depth -= 1
                if depth == 0:
                    return i
        i += 1
    return -1


def back(src, mask, i, op, cl):
    """i at a closer; index of its opener, or -1."""
    depth = 0
    while i >= 0:
        if mask[i]:
            if src[i] == cl:
                depth += 1
            elif src[i] == op:
                depth -= 1
                if depth == 0:
                    return i
        i -= 1
    return -1


def lskip(src, i):
    while i >= 0 and src[i] in " \t\r\n":
        i -= 1
    return i


def rskip(src, i):
    while i < len(src) and src[i] in " \t\r\n":
        i += 1
    return i


def chain_start(src, mask, p):
    """p at the `.` / `->` of a call's link; the index where the postfix
    chain it continues starts (a name, `self`, a call, a parenthesized
    primary, through `.`, `->`, `?.`, `::`, calls, indexes, generics)."""
    i = p
    while True:
        j = lskip(src, i - 1)
        if j < 0 or not mask[j]:
            return i                      # never into a comment or a string
        # one postfix element ending at j
        while True:
            if src[j] in ")]" and mask[j]:
                o = back(src, mask, j, "(" if src[j] == ")" else "[", src[j])
                if o < 0:
                    return i
                k = o - 1
                if k >= 0 and (IDCH.match(src[k]) or src[k] in ">]"):
                    j = k
                    continue
                if k >= 0 and src[k] == ")":
                    j = k
                    continue
                start = o
                break
            if src[j] == ">" and j > 0 and src[j - 1] != "-":
                o = back(src, mask, j, "<", ">")
                if o > 0 and IDCH.match(src[o - 1]):
                    j = o - 1
                    continue
                return i
            if IDCH.match(src[j]):
                k = j
                while k > 0 and IDCH.match(src[k - 1]):
                    k -= 1
                start = k
                break
            return i
        # what links it to the element before?
        k = lskip(src, start - 1)
        if k < 0 or not mask[k]:
            return start
        if k >= 1 and src[k - 1:k + 1] in ("::", "->", "?."):
            i = k - 1
            continue
        if k >= 0 and src[k] == "." and (k == 0 or src[k - 1] != "."):
            i = k
            continue
        return start


def enclosing(spans, pos):
    best = None
    for s in spans:
        if s[0] <= pos < s[1] and (best is None or s[0] > best[0]):
            best = s
    return best


def type_spans(src, mask):
    out = []
    for m in TYPEHEAD.finditer(src):
        if not mask[m.start()]:
            continue
        ob = m.end() - 1
        cb = fwd(src, mask, ob, "{", "}")
        if cb > 0:
            base = re.search(r"\bderives\s+(.*)", m.group(3) or "")
            out.append((ob, cb, m.group(1), base.group(1).strip() if base else ""))
    return out


def fn_of(src, mask, at):
    """For a `->` at `at`: (fn name, fn keyword index, body `{` or -1)."""
    ls = src.rfind("\n", 0, at) + 1
    k = at
    # walk back to the `fn` keyword (a signature may span lines)
    while True:
        m = None
        for m in re.finditer(r"\bfn\b", src[ls:at]):
            pass
        if m and mask[ls + m.start()]:
            fk = ls + m.start()
            break
        if ls == 0:
            return None
        ls = src.rfind("\n", 0, ls - 1) + 1
        if at - ls > 2000:
            return None
    nm = re.match(r"fn\s+(?:<[^>]*>\s*)?(op\b|[A-Za-z_]\w*)", src[fk:])
    name = nm.group(1) if nm else "?"
    # body: first `{` / `;` / `=` at depth 0 after the return type
    i, depth = at, 0
    while i < len(src):
        if mask[i]:
            c = src[i]
            if c in "([":
                depth += 1
            elif c in ")]":
                depth -= 1
            elif depth == 0 and c == "{":
                return name, fk, i
            elif depth == 0 and c in ";\n" and src[i - 1] != ",":
                return name, fk, -1
        i += 1
    return name, fk, -1


def is_postfix(e):
    e = e.strip()
    return bool(re.fullmatch(r"[A-Za-z_][\w.:>\-\[\]()]*", e)) and "--" not in e and not re.search(r"[^-]>", e.replace("->", ""))


def rewrite(src, path, report):
    mask = full_mask(src)
    rel = path.replace("\\", "/")
    edits = []          # (start, end, text)
    ptr_fns = []        # (body_start, body_end) of functions now returning a pointer
    types = type_spans(src, mask)

    # ---- definitions --------------------------------------------------------
    for m in RETREF.finditer(src):
        if not mask[m.start()]:
            continue
        a = m.end() - 1
        b = fwd(src, mask, a, "(", ")")
        if b < 0:
            continue
        inner = src[a + 1:b].strip()
        line = src.count("\n", 0, m.start()) + 1
        fi = fn_of(src, mask, m.start())
        if fi is None:
            continue
        name, fk, ob = fi
        if name == "op":
            report.append(f"{path}:{line}: `op =` returning ref!({inner}) left (an explicit op = is no Stage 1 form)")
            continue
        owner = enclosing(types, m.start())
        if owner and re.match(r"(clang|llvm|cxx|libcxx)::", owner[3]):
            base = owner[3].split(",")[0].strip()
            ls = src.rfind("\n", 0, fk) + 1
            ind = re.match(r"[ \t]*", src[ls:]).group(0)
            edits.append((ls, ls, f"{ind}// TODO(CXX-REF): matches {base}::{name}\n"))
            edits.append((m.start(), b + 1, f"-> __builtin_cxx_lvalue_ref<{inner}>"))
            report.append(f"{path}:{line}: CXX-REF {name} overrides {base}::{name}; kept as T&")
            continue
        if name not in CALLS:
            report.append(f"{path}:{line}: `{name}` returns ref!({inner}) but is not in CALLS; "
                          "its call sites are NOT rewritten")
        self_ty = owner and re.sub(r"\s+", "", inner) == owner[2]
        edits.append((m.start(), b + 1, "-> unsafe *Self" if self_ty else f"-> unsafe *{inner}"))
        if ob < 0:
            continue
        cb = fwd(src, mask, ob, "{", "}")
        ptr_fns.append((ob, cb))
        for r in re.finditer(r"\breturn\b[ \t]*", src[ob:cb]):
            rs = ob + r.end()
            if not mask[ob + r.start()]:
                continue
            # the returned expression: to `;`, `}` or end of line at depth 0
            i, depth = rs, 0
            while i < cb:
                c = src[i]
                if mask[i]:
                    if c in "([{":
                        depth += 1
                    elif c in ")]}":
                        if depth == 0:
                            break
                        depth -= 1
                    elif depth == 0 and c == ";":
                        break
                if c == "\n" and depth == 0:
                    break
                i += 1
            e = src[rs:i].rstrip()
            if not e:
                continue
            if e == "self":
                edits.append((rs, rs, "unsafe &"))
                continue
            last = re.search(r"[.>]\s*([A-Za-z_]\w*)\s*(?:<[^()]*>)?\s*\([^()]*(?:\([^()]*\)[^()]*)*\)$", e)
            if last and last.group(1) in CALLS:
                continue                       # already a pointer
            if e.startswith("&") or e.startswith("unsafe"):
                continue
            edits.append((rs, rs, "unsafe &") if is_postfix(e) else (rs, rs + len(e), f"unsafe &({e})"))

    # a second run: the defs above are `-> *T` already, and a `return f()`
    # in one of them still passes the pointer through
    for m in re.finditer(r"->\s*(?:unsafe\s+)?\*", src):
        if not mask[m.start()]:
            continue
        fi = fn_of(src, mask, m.start())
        if fi and fi[0] in CALLS and fi[2] > 0:
            ptr_fns.append((fi[2], fwd(src, mask, fi[2], "{", "}")))

    # ---- by-reference range-for ---------------------------------------------
    for m in FORREF.finditer(src):
        if not mask[m.start()]:
            continue
        a = m.end() - 1
        b = fwd(src, mask, a, "(", ")")
        if b < 0:
            continue
        nm = m.group(1)
        edits.append((m.start(), b + 1, f"for *{nm}"))
        ob = src.find("{", b)
        cb = fwd(src, mask, ob, "{", "}") if ob > 0 else -1
        if cb < 0:
            continue
        for u in re.finditer(r"(?<![\w$#])" + re.escape(nm) + r"(?!\w)", src[ob:cb]):
            us = ob + u.start()
            if not mask[us]:
                continue
            pre = src[lskip(src, us - 1) - 1:lskip(src, us - 1) + 1]
            if pre.endswith(".") or pre in ("->", "::"):
                continue
            after = rskip(src, us + len(nm))
            if src[after:after + 1] == "." and src[after:after + 2] != "..":
                edits.append((after, after + 1, "->"))
            elif src[us - 1:us] == "*":
                continue
            else:
                edits.append((us, us + len(nm), f"(*{nm})"))

    # ---- call sites ----------------------------------------------------------
    for m in re.finditer(r"(\.|->|\?\.)[ \t]*([A-Za-z_]\w*)[ \t]*(<[^()<>]*(?:<[^()<>]*>[^()<>]*)*>)?[ \t]*\(", src):
        name = m.group(2)
        if name not in CALLS or not mask[m.start()]:
            continue
        kind, chain, files, skip_recv = CALLS[name]
        if files and not any(rel == f or rel.endswith("/" + f) for f in files):
            continue
        # a definition's own name is `fn name(`, never `.name(`; skip fn heads
        if re.search(r"\bfn\s*$", src[max(0, m.start() - 8):m.start()]):
            continue
        st = chain_start(src, mask, m.start())
        if skip_recv and skip_recv.search(src[st:m.start()].strip()):
            continue
        cp = m.end() - 1
        ce = fwd(src, mask, cp, "(", ")")
        if ce < 0:
            continue
        # see through wrapping parens: `(x.f()).g`
        s2, e2 = st, ce
        while True:
            a = lskip(src, s2 - 1)
            b = rskip(src, e2 + 1)
            if a >= 0 and src[a] == "(" and b < len(src) and src[b] == ")" and \
                    fwd(src, mask, a, "(", ")") == b and not (a > 0 and IDCH.match(src[lskip(src, a - 1)])):
                s2, e2 = a, b
                continue
            break
        nx = rskip(src, e2 + 1)
        line = src.count("\n", 0, m.start()) + 1
        if src[nx:nx + 2] == "->":
            continue                                  # done already
        mem = re.match(r"\.[ \t]*([A-Za-z_]\w*)[ \t]*(<[^()]*>)?[ \t]*(\()?", src[nx:])
        if mem and src[nx:nx + 2] != "..":
            # a builder's next link must be a CALL of its chain: `.first` the
            # field of a pair is not DiagBuilder::first
            if kind == "accessor" or (mem.group(1) in chain and mem.group(3)):
                edits.append((nx, nx + 1, "->"))
            else:
                report.append(f"{path}:{line}: `.{mem.group(1)}` after `{name}()` is not of its chain; left")
            continue
        pre_i = lskip(src, s2 - 1)
        pre = src[pre_i] if pre_i >= 0 else "\n"
        if pre == "*":
            continue                                  # done already
        if pre == "&":
            report.append(f"{path}:{line}: `&...{name}()` is now the pointer itself; drop the `&` by hand")
            continue
        stmt_start = pre in "{;}\n" or pre_i < 0 or src[s2 - 1:s2] == "\n" or \
            src[src.rfind("\n", 0, s2) + 1:s2].strip() == ""
        stmt_end = src[nx:nx + 1] in (";", "}", "\n", "") or src[nx:nx + 2] == "//" or \
            src[e2 + 1:src.find("\n", e2 + 1) if src.find("\n", e2 + 1) > 0 else len(src)].strip() in ("", ";")
        if kind == "builder" and stmt_start and stmt_end:
            continue
        if name in DIAG and kind == "builder":
            # DiagBuilder is move-only, so no Stage 0 code used one of its
            # chains as a copied value; a "value use" of these common names
            # (`r.first()`, `self.highlight(...)`) is another type's method
            report.append(f"{path}:{line}: `{name}()` used as a value; not DiagBuilder's (left)")
            continue
        before = src[src.rfind("\n", 0, s2) + 1:s2]
        if re.search(r"\breturn\s*$", before) and enclosing([(a, b, "", "") for a, b in ptr_fns], s2):
            continue
        edits.append((st, st, "*"))
        if kind == "builder":
            report.append(f"{path}:{line}: builder `{name}()` used as a value; dereferenced")

    edits = sorted(set(edits), key=lambda e: (e[0], e[1]), reverse=True)
    for a, b, t in edits:
        src = src[:a] + t + src[b:]
    return src, len(edits)


CASES = [
    ("class DiagBuilder {\n    fn first(self, r: R) -> ref!(DiagBuilder) {\n        if !r.ok() { return self; }\n"
     "        return self;\n    }\n    fn note(self, m: string) -> ref!(DiagBuilder) {\n        return self._add_child_no_loc(m);\n    }\n}\n",
     "class DiagBuilder {\n    fn first(self, r: R) -> unsafe *Self {\n        if !r.ok() { return unsafe &self; }\n"
     "        return unsafe &self;\n    }\n    fn note(self, m: string) -> unsafe *Self {\n        return self._add_child_no_loc(m);\n    }\n}\n"),
    ("class CI {\n    fn invocation(self)   -> ref!(CompilerInvocation) { return self._inv;     }\n}\n",
     "class CI {\n    fn invocation(self)   -> unsafe *CompilerInvocation { return unsafe &self._inv;     }\n}\n"),
    ("class P {\n    fn get_list(self, key: string) -> ref!(vec<string>) {\n        return self._map[key].as_list();\n    }\n}\n",
     "class P {\n    fn get_list(self, key: string) -> unsafe *vec<string> {\n        return self._map[key].as_list();\n    }\n}\n"),
    ("    self.diag->report(X, r).first(tok->range).note(\"a\").emit();\n",
     "    self.diag->report(X, r).first(tok->range)->note(\"a\")->emit();\n"),
    ("    b.first(r)\n        .note(\"x\")\n        .emit()\n",
     "    b.first(r)\n        ->note(\"x\")\n        ->emit()\n"),
    ("    b.insert(at, \"x\", \"m\");\n", "    b.insert(at, \"x\", \"m\");\n"),
    ("    var ok = m.insert(k).first\n", "    var ok = m.insert(k).first\n"),
    ("    cmd->define(FlagDef::x(\"a\"));\n", "    cmd->define(FlagDef::x(\"a\"));\n"),
    ("    cmd.define<FlagKind::Bool>(\"a\", \"b\").define<FlagKind::I32>(\"c\", \"d\");\n",
     "    cmd.define<FlagKind::Bool>(\"a\", \"b\")->define<FlagKind::I32>(\"c\", \"d\");\n"),
    ("    var rb = ImportResolver::Builder().cwd(cwd);\n", "    var rb = *ImportResolver::Builder().cwd(cwd);\n"),
    ("    var r = ImportResolver::Builder()\n        .cwd(p)\n        .add_includes(i)\n        .create_ptr();\n",
     "    var r = ImportResolver::Builder()\n        .cwd(p)\n        ->add_includes(i)\n        ->create_ptr();\n"),
    ("    // a comment (x).\n    cmd->define(FlagDef::x(\"a\"));\n", "    // a comment (x).\n    cmd->define(FlagDef::x(\"a\"));\n"),
    ("    self.well_known->_set(k, r.first());\n", "    self.well_known->_set(k, r.first());\n"),
    ("    for d: string in self.invocation().include_dirs { }\n",
     "    for d: string in self.invocation()->include_dirs { }\n"),
    ("    f(self.invocation(), x);\n", "    f(*self.invocation(), x);\n"),
    ("    (ci->invocation()).frontend.x = 1\n", "    (ci->invocation())->frontend.x = 1\n"),
    ("    var t = be->invocation()->getTargetOpts()\n", "    var t = be->invocation()->getTargetOpts()\n"),
    ("    for x in args.get_list(\"I\") { }\n", "    for x in *args.get_list(\"I\") { }\n"),
]
CASES_LEXER = [
    ("        ctx.imm.get_suffix() = suffix.range;\n        (ctx.imm.get_prefix()) = ctx.prefix;\n"
     "        ctx.imm.get_exprs().push_back(x);\n",
     "        *ctx.imm.get_suffix() = suffix.range;\n        (*ctx.imm.get_prefix()) = ctx.prefix;\n"
     "        ctx.imm.get_exprs()->push_back(x);\n"),
    ("    for var slot: ref!(Slot) in _slots {\n        if slot.lexer != &null { f(slot); }\n    }\n",
     "    for *slot in _slots {\n        if slot->lexer != &null { f((*slot)); }\n    }\n"),
    ("    for var q: ref!(unsafe *PartitionQueue) in self._queues {\n        delete q;\n    }\n",
     "    for *q in self._queues {\n        delete (*q);\n    }\n"),
]
CASES_OTHER = [
    ("class Token {\n    fn op = (self, new: TokenKind) -> ref!(Token) {\n        return self;\n    }\n}\n",
     "class Token {\n    fn op = (self, new: TokenKind) -> ref!(Token) {\n        return self;\n    }\n}\n"),
    ("class C derives clang::ASTConsumer {\n    fn thing(self) -> ref!(Foo) {\n        return self._f;\n    }\n}\n",
     "class C derives clang::ASTConsumer {\n    // TODO(CXX-REF): matches clang::ASTConsumer::thing\n"
     "    fn thing(self) -> __builtin_cxx_lvalue_ref<Foo> {\n        return self._f;\n    }\n}\n"),
    ("    var holes = n->get_holes();\n", "    var holes = n->get_holes();\n"),
    ("class <const N: usize> Buf {\n    fn me(self) -> ref!(Buf) {\n        return self;\n    }\n}\n",
     "class <const N: usize> Buf {\n    fn me(self) -> unsafe *Self {\n        return unsafe &self;\n    }\n}\n"),
]


def selftest():
    bad = 0
    for path, cases in (("Compiler/X.k", CASES), ("Compiler/Lexer/Lexer.k", CASES_LEXER),
                        ("Compiler/Sema/Type/LiteralTyping.k", CASES_OTHER)):
        for src, want in cases:
            got, _ = rewrite(src, path, [])
            again, _ = rewrite(got, path, [])
            ok = got == want and again == got
            bad += not ok
            print(("ok   " if ok else "FAIL ") + src.replace("\n", "\\n")[:80]
                  + ("" if ok else f"\n     got  {got!r}\n     want {want!r}\n     again {again!r}"))
    n = len(CASES) + len(CASES_LEXER) + len(CASES_OTHER)
    print(f"\n{n - bad}/{n} passed")
    return 1 if bad else 0


if __name__ == "__main__":
    if "--selftest" in sys.argv[1:]:
        sys.exit(selftest())
    sys.exit(run(rewrite, "-> ref!(T) -> -> *T (+ call sites), for x: ref!(T) in -> for *x in"))
