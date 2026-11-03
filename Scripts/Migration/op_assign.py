#!/usr/bin/env python3
# Stage 0 `fn op = (...)` -> what Stage 1 has instead, each marked
# `// TODO(OP-ASSIGN): ...` for review.
#
# Stage 1 GENERATES `op =` from the transfer constructor, and writing one is a
# compile error (Spec/Docs classes-lifecycle, "op ="): a deleted transfer
# constructor means no assignment, a defaulted one member-wise assignment,
# one with a body "checks for self-assignment, destroys self, rebuilds it in
# place through the transfer constructor". The interim decision (2026-11-03):
#
#   - a same-type `op =` -- deleted, member-wise, or self-check + destroy +
#     the transfer constructor's body -- is what Stage 1 derives: DROPPED.
#     Which classes qualify was read by hand (DROP below, with what the
#     derived one differs in, if anything); a same-type op = of a class not
#     listed is reported and left;
#   - Token's heterogeneous `token = kind` / `= range` / `= imm` are no
#     assignment at all: they become `set_kind` / `set_range` / `set_imm`,
#     and their call sites -- a statement `x = rhs` where x is a local or
#     parameter declared as a Token in the same function -- become
#     `x.set_kind(rhs)` etc., by the right-hand side's spelling (TokenKind /
#     a source range). Any other assignment to a Token whose right side is
#     neither is reported.
#
# Deletes lines, so it runs after cpp_casts; before ref_returns and
# ref_and_mref, which would otherwise rewrite the `-> ref!(T)` of these.
#
#     python3 Scripts/Migration/op_assign.py <copy-of-tree> [--apply]
#     python3 Scripts/Migration/op_assign.py --selftest
import os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kairo_lex import code_mask, run

# class -> note on how Stage 1's derived op = differs ("" when it does not)
DROP = {
    "TokenBuffer": "",
    "PublishOnExit": "",
    "OwnedUnit": "",
    "TimeRegion": "", "TimeSampled": "", "TimeWorker": "", "TimeThreadRoot": "",
    "MappedFileBuffer": "",
    "FileEntry": "",
    "MemoryBuffer": "",
    "Task": "",
    "ArenaAllocator": "it had a copy AND a move op =, both stealing; Stage 1 has one transfer constructor",
    "DiagBuilder": "the derived op = runs the destructor, which ICE-fails on an un-emitted builder "
                   "where this one freed it silently",
}
SETTERS = {"TokenKind": ("set_kind", "kind"), "SourceRange": ("set_range", "range"), "u32": ("set_imm", "imm")}

OPEQ = re.compile(r"^([ \t]*)((?:(?:pub|priv|prot|inline|delete)\s+)*)fn\s*op\s*=\s*\(\s*self\s*,\s*([A-Za-z_]\w*)\s*:\s*([^()]*(?:\([^()]*\))?[^()]*)\)", re.M)
TYPEHEAD = re.compile(r"\b(?:class|struct)\s+(?:<[^{;]*?>\s*)?([A-Za-z_]\w*)[^{;]*\{")
FNHEAD = re.compile(r"\bfn\b[^{;]*?\{")


def _match(src, mask, i):
    depth = 0
    while i < len(src):
        if mask[i]:
            if src[i] == "{":
                depth += 1
            elif src[i] == "}":
                depth -= 1
                if depth == 0:
                    return i
        i += 1
    return -1


def _owner(src, mask, pos):
    best = None
    for k in re.finditer(r"\b(?:class|struct)\b", src):
        # one match per CODE keyword: a finditer would let a `class X` in a
        # doc comment swallow the real declaration after it
        if not mask[k.start()]:
            continue
        m = TYPEHEAD.match(src, k.start())
        if not m or not all(mask[j] for j in range(k.start(), m.end()) if src[j] == "{"):
            continue
        ob = m.end() - 1
        cb = _match(src, mask, ob)
        if ob < pos < cb and (best is None or ob > best[0]):
            best = (ob, m.group(1))
    return best[1] if best else None


def _param_type(t):
    t = t.strip()
    t = re.sub(r"^(?:@inout|@move|const)\s+", "", t)
    m = re.fullmatch(r"(?:m?ref!?)\((.*)\)", t)
    return (m.group(1) if m else t).strip()


def rewrite(src, path, report):
    mask = code_mask(src)
    edits = []
    for m in OPEQ.finditer(src):
        if not mask[m.start(2) if m.group(2) else m.start()]:
            continue
        ind = m.group(1)
        line = src.count("\n", 0, m.start()) + 1
        owner = _owner(src, mask, m.start())
        ptype = _param_type(m.group(4))
        # extent: a `;`-terminated declaration, or the body's closing brace
        k = m.end()
        while k < len(src) and src[k] not in "{;\n":
            k += 1
        nl = src.find("\n", k)
        if k < len(src) and src[k] == "{":
            cb = _match(src, mask, k)
            end = src.find("\n", cb)
        else:
            cb = k
            end = nl
        end = len(src) if end < 0 else end
        if owner == "Token" and ptype in SETTERS:
            name, field = SETTERS[ptype]
            body = src[k:cb + 1] if src[k:k + 1] == "{" else ""
            body = re.sub(r"\n[ \t]*return\s+self\s*;?[ \t]*(?=\n)", "", body)
            edits.append((m.start(), end,
                          f"{ind}// TODO(OP-ASSIGN): was `token = <{ptype}>` (op =, not an assignment); "
                          f"call sites -> {name}\n"
                          f"{ind}fn {name}(self, {m.group(3)}: {ptype}) {body}"))
            continue
        if owner in DROP and re.sub(r"<.*", "", ptype) == owner:
            note = DROP[owner]
            what = "deleted copy op =" if "delete" in (m.group(2) or "") else "op ="
            text = f"{ind}// TODO(OP-ASSIGN): {what} dropped; Stage 1 derives op = from the transfer constructor"
            edits.append((m.start(), end, text + (f" ({note})" if note and what == "op =" else "")))
            continue
        report.append(f"{path}:{line}: `op =` of {owner}({ptype}) is not in op_assign's table; left")

    for a, b, t in reversed(edits):
        src = src[:a] + t + src[b:]
    n = len(edits)
    src, c = _call_sites(src, path, report)
    return src, n + c


def _call_sites(src, path, report):
    """x = rhs -> x.set_kind(rhs) for Token locals and parameters."""
    mask = code_mask(src)
    edits = []
    for f in FNHEAD.finditer(src):
        if not mask[f.start()]:
            continue
        ob = f.end() - 1
        cb = _match(src, mask, ob)
        if cb < 0:
            continue
        head = src[f.start():ob]
        names = set(re.findall(r"([A-Za-z_]\w*)\s*:\s*(?:@inout\s+)?Token\b(?!\w|\s*[<:])", head))
        body = src[ob:cb]
        names |= set(re.findall(r"\bvar\s+([A-Za-z_]\w*)\s*(?::\s*Token\b(?!\w|\s*::)|=\s*Token\s*\(\s*\))", body))
        if not names:
            continue
        for a in re.finditer(r"(?m)^([ \t]*)(" + "|".join(map(re.escape, sorted(names))) +
                             r")[ \t]*=(?!=)[ \t]*([^;\n]+?)[ \t]*(;?)(?=[ \t]*(?://.*)?$)", body):
            at = ob + a.start(2)
            if not mask[at]:
                continue
            rhs = a.group(3)
            if re.search(r"\bTokenKind\b", rhs):
                fn = "set_kind"
            elif re.search(r"create_source_range|SourceRange\b|\.range\b", rhs):
                fn = "set_range"
            elif re.fullmatch(r"[\s()\d]*|.*\bintern_ident\(.*|(\(?if\b.*=>\s*\(?\d+\)?\s*else\s*=>\s*\(?\d+\)?\)?)", rhs.split("//")[0].strip()):
                fn = "set_imm"             # an immediate index / literal
            else:
                continue                   # Token = Token: Stage 1's own op =
            edits.append((ob + a.start(2), ob + a.end(), f"{a.group(2)}.{fn}({rhs}){a.group(4)}"))
    for s, e, t in reversed(edits):
        src = src[:s] + t + src[e:]
    return src, len(edits)


CASES = [
    ("class Token {\n    fn op = (self, new: TokenKind) -> ref!(Token) {\n        self.kind = new;\n        return self;\n    }\n}\n",
     "class Token {\n    // TODO(OP-ASSIGN): was `token = <TokenKind>` (op =, not an assignment); call sites -> set_kind\n"
     "    fn set_kind(self, new: TokenKind) {\n        self.kind = new;\n    }\n}\n"),
    ("class TokenBuffer {\n    delete fn op = (self, other: ref!(TokenBuffer)) -> ref!(TokenBuffer);\n    var x: i32\n}\n",
     "class TokenBuffer {\n    // TODO(OP-ASSIGN): deleted copy op = dropped; Stage 1 derives op = from the transfer constructor\n    var x: i32\n}\n"),
    ("class <const N: usize> TokenBuffer {\n    fn op = (self, other: mref!(TokenBuffer)) -> ref!(TokenBuffer) {\n"
     "        if (&self) == (&other) { return self; }\n        self.destroy();\n    }\n    fn g(self) { }\n}\n",
     "class <const N: usize> TokenBuffer {\n    // TODO(OP-ASSIGN): op = dropped; Stage 1 derives op = from the transfer constructor\n"
     "    fn g(self) { }\n}\n"),
    ("class Task {\n    fn op=(self, other: mref!(Task)) {\n        self._fn = other._fn;\n    }\n}\n",
     "class Task {\n    // TODO(OP-ASSIGN): op = dropped; Stage 1 derives op = from the transfer constructor\n}\n"),
    ("class Other {\n    fn op = (self, o: Other) { }\n}\n", "class Other {\n    fn op = (self, o: Other) { }\n}\n"),
    ("fn lex(self) -> Token {\n    var token = Token();\n    token = TokenKind::AtComment;\n"
     "    token = self.create_source_range(start);\n    token.imm = 3;\n    return token;\n}\n",
     "fn lex(self) -> Token {\n    var token = Token();\n    token.set_kind(TokenKind::AtComment);\n"
     "    token.set_range(self.create_source_range(start));\n    token.imm = 3;\n    return token;\n}\n"),
    ("fn f(self, tok: Token) {\n    tok = if c => TokenKind::A else => TokenKind::B\n}\n",
     "fn f(self, tok: Token) {\n    tok.set_kind(if c => TokenKind::A else => TokenKind::B)\n}\n"),
    ("fn f(self, t: Token) {\n    t = if d => (1) else => (2); // doc\n    t = self.intern_ident(p, n, h)\n    t = other\n}\n",
     "fn f(self, t: Token) {\n    t.set_imm(if d => (1) else => (2)); // doc\n    t.set_imm(self.intern_ident(p, n, h))\n    t = other\n}\n"),
    ("/// class Task doc\nclass Task {\n    fn op=(self, other: mref!(Task)) { }\n}\n",
     "/// class Task doc\nclass Task {\n    // TODO(OP-ASSIGN): op = dropped; Stage 1 derives op = from the transfer constructor\n}\n"),
    ("fn f(self) {\n    var kind = TokenKind::A;\n    kind = TokenKind::B;\n}\n",
     "fn f(self) {\n    var kind = TokenKind::A;\n    kind = TokenKind::B;\n}\n"),
]


def selftest():
    bad = 0
    for src, want in CASES:
        got, _ = rewrite(src, "<selftest>", [])
        again, n2 = rewrite(got, "<selftest>", [])
        ok = got == want and n2 == 0 and again == got
        bad += not ok
        print(("ok   " if ok else "FAIL ") + src.replace("\n", "\\n")[:80]
              + ("" if ok else f"\n     got  {got!r}\n     want {want!r}"))
    print(f"\n{len(CASES) - bad}/{len(CASES)} passed")
    return 1 if bad else 0


if __name__ == "__main__":
    if "--selftest" in sys.argv[1:]:
        sys.exit(selftest())
    sys.exit(run(rewrite, "op = -> dropped (Stage 1 derives it) / Token setters"))
