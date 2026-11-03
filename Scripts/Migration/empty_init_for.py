#!/usr/bin/env python3
# for (; cond; step) { body }  ->  while cond { body; step }
#
# Stage 0 takes C's three-clause `for` with an empty init. Stage 1's C-style
# `for` declares its variable in the init clause (Spec/Docs control-flow,
# "for C-style": "The init clause declares a new variable scoped to the loop
# body"), and an empty one is S056E "expected '{' after C-style for header".
# The loop variable of these sites lives on after the loop (SourceLineTable's
# SIMD strides hand `i` from one stride to the next), so it cannot move into
# the head; the loop becomes a `while` with the step at the end of the body
# (the user's call, 2026-11-03).
#
# `continue` is the one way that changes meaning: in the `for` it ran the
# step, in the `while` it would skip it. Every `continue` that belongs to
# this loop (not to a loop nested in its body, not a labeled one) becomes
# `step; continue`. An empty condition is `loop`; an empty step adds nothing.
# Each rewritten loop carries `// TODO(LOOP-PORT): ...` with its original
# head, for the user to review.
#
# 8 sites on 2026-11-03: SourceLineTable.k x5, CompilerInstance.k x2,
# DirEntry.k x1 (the last three with a `continue`).
#
#     python3 Scripts/Migration/empty_init_for.py <copy-of-tree> [--apply]
#     python3 Scripts/Migration/empty_init_for.py --selftest
import os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kairo_lex import code_mask, run

HEAD = re.compile(r"\bfor[ \t]*(\(?)[ \t]*;")
CHARLIT = re.compile(r"r?'(?:\\x[0-9A-Fa-f]{1,8}|\\.|[^'\\\n])'")
LOOPKW = re.compile(r"\b(for|while|loop)\b")
CONT = re.compile(r"\bcontinue\b(?![ \t]+[A-Za-z_])")


def _skip(src, mask, i):
    """Index past a non-code run or a char literal at i, else i."""
    if not mask[i]:
        while i < len(src) and not mask[i]:
            i += 1
        return i
    if src[i] == "'" or (src[i] == "r" and src[i + 1:i + 2] == "'"):
        m = CHARLIT.match(src, i)
        if m:
            return m.end()
    return i


def _match(src, mask, i, op, cl):
    """i at an opener; index of its closer, or -1."""
    depth, n = 0, len(src)
    while i < n:
        j = _skip(src, mask, i)
        if j != i:
            i = j
            continue
        c = src[i]
        if c == op:
            depth += 1
        elif c == cl:
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def _split_top(src, mask, a, b, stop_at_brace=False):
    """Split src[a:b] on `;` at bracket depth 0; with stop_at_brace, end at
    the first depth-0 `{` and return its index as well."""
    parts, depth, i, start = [], 0, a, a
    while i < b:
        j = _skip(src, mask, i)
        if j != i:
            i = j
            continue
        c = src[i]
        if c in "([":
            depth += 1
        elif c in ")]":
            depth -= 1
        elif depth == 0 and c == ";":
            parts.append(src[start:i])
            start = i + 1
        elif depth == 0 and c == "{" and stop_at_brace:
            parts.append(src[start:i])
            return parts, i
        i += 1
    parts.append(src[start:b])
    return parts, b


def _nested_bodies(src, mask, a, b):
    """[s, e) of the body of every loop nested in src[a:b]."""
    spans = []
    for m in LOOPKW.finditer(src, a, b):
        if not mask[m.start()]:
            continue
        k = m.end()
        depth = 0
        while k < b:
            j = _skip(src, mask, k)
            if j != k:
                k = j
                continue
            c = src[k]
            if c in "([":
                depth += 1
            elif c in ")]":
                depth -= 1
            elif c == "{" and depth == 0:
                e = _match(src, mask, k, "{", "}")
                if e > 0:
                    spans.append((k, e))
                break
            elif c in ";\n" and depth == 0 and m.group(1) != "for":
                break
            k += 1
    return spans


def _one(src, mask, m):
    """(start, end, replacement) for the loop whose head HEAD matched, or None."""
    paren = m.group(1) == "("
    if paren:
        o = src.index("(", m.start())
        c = _match(src, mask, o, "(", ")")
        if c < 0:
            return None
        parts, _ = _split_top(src, mask, o + 1, c)
        k = c + 1
        while k < len(src) and src[k] in " \t":
            k += 1
        if k >= len(src) or src[k] != "{":
            return None
        ob = k
    else:
        parts, ob = _split_top(src, mask, m.end() - 1, len(src), stop_at_brace=True)
        parts = [""] + parts[1:] if parts else parts
        if ob >= len(src) or src[ob] != "{":
            return None
    if len(parts) != 3 or parts[0].strip():
        return None
    cond, step = parts[1].strip(), parts[2].strip()
    cb = _match(src, mask, ob, "{", "}")
    if cb < 0:
        return None

    ls = src.rfind("\n", 0, m.start()) + 1
    ind = re.match(r"[ \t]*", src[ls:]).group(0)
    orig = "for " + ("(" if paren else "") + "; " + cond + "; " + step + (")" if paren else "")
    if not cond and not step:
        orig = "for (;;)" if paren else "for ;;"
    body = src[ob + 1:cb]

    # continues of THIS loop take the step with them
    conts = 0
    if step:
        inner = _nested_bodies(src, mask, ob + 1, cb)
        hits = [x for x in CONT.finditer(src, ob + 1, cb)
                if mask[x.start()] and not any(s < x.start() < e for s, e in inner)]
        conts = len(hits)
        for x in reversed(hits):
            o = x.start() - (ob + 1)
            body = body[:o] + step + "; continue" + body[o + len("continue"):]

    note = f"{ind}// TODO(LOOP-PORT): was `{orig}`" + ("; the step now ends the body" if step else "")
    if conts:
        note += f" and precedes each of its {conts} `continue`"
    head = f"while {cond} {{" if cond else "loop {"
    if step:
        tail_ls = body.rfind("\n")
        if tail_ls >= 0 and not body[tail_ls + 1:].strip():
            cl_ind = body[tail_ls + 1:]
            body = body[:tail_ls] + f"\n{cl_ind}    {step}\n{cl_ind}"
        else:
            body = body.rstrip() + f"; {step} "
    return (ls if src[ls:m.start()].strip() == "" else m.start(), cb + 1,
            (note + "\n" + src[ls:m.start()] if src[ls:m.start()].strip() == "" else "") + head + body + "}",
            m.start())


def rewrite(src, path, report):
    mask = code_mask(src)
    edits = []
    for m in HEAD.finditer(src):
        if not mask[m.start()]:
            continue
        r = _one(src, mask, m)
        if r is None:
            line = src.count("\n", 0, m.start()) + 1
            report.append(f"{path}:{line}: empty-init `for` not understood; left as is")
            continue
        edits.append(r)
    # inner loops first is unnecessary: an empty-init loop nested in another
    # would overlap; take outermost only and let a second sweep do the rest.
    edits.sort(key=lambda e: e[0])
    kept, last = [], -1
    for e in edits:
        if e[0] >= last:
            kept.append(e)
            last = e[1]
    for a, b, t, _ in reversed(kept):
        src = src[:a] + t + src[b:]
    if len(kept) < len(edits):
        again, n = rewrite(src, path, report)
        return again, len(kept) + n
    return src, len(kept)


CASES = [
    ("        for (; i < size; ++i) {\n            f(i);\n        }\n",
     "        // TODO(LOOP-PORT): was `for (; i < size; ++i)`; the step now ends the body\n"
     "        while i < size {\n            f(i);\n            ++i\n        }\n"),
    ("    for (; (!ec) && (it != end); it.increment(ec)) {\n"
     "        if x { continue; }\n        for y in ys { if z { continue } }\n        g();\n    }\n",
     "    // TODO(LOOP-PORT): was `for (; (!ec) && (it != end); it.increment(ec))`; the step now ends the body"
     " and precedes each of its 1 `continue`\n"
     "    while (!ec) && (it != end) {\n        if x { it.increment(ec); continue; }\n"
     "        for y in ys { if z { continue } }\n        g();\n        it.increment(ec)\n    }\n"),
    ("    for ; i < n; i += 2 {\n        f()\n    }\n",
     "    // TODO(LOOP-PORT): was `for ; i < n; i += 2`; the step now ends the body\n"
     "    while i < n {\n        f()\n        i += 2\n    }\n"),
    ("    for (;;) {\n        f()\n    }\n",
     "    // TODO(LOOP-PORT): was `for (;;)`\n    loop {\n        f()\n    }\n"),
    ("    for (; c == '{'; ++i) { f() }\n",
     "    // TODO(LOOP-PORT): was `for (; c == '{'; ++i)`; the step now ends the body\n"
     "    while c == '{' { f(); ++i }\n"),
    ("    for var i = 0; i < n; ++i {\n    }\n", "    for var i = 0; i < n; ++i {\n    }\n"),
    ("    // for (; a; b) {\n", "    // for (; a; b) {\n"),
    ('    s = "for (; a; b) {"\n', '    s = "for (; a; b) {"\n'),
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
    sys.exit(run(rewrite, "for (; cond; step) { } -> while cond { ...; step }"))
