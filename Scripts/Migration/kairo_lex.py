#!/usr/bin/env python3
# Shared lexer-lite + CLI driver for the mechanical .k migrations in this
# folder. Not a parser: it only has to be right about which byte offsets are
# Kairo CODE, so a rewrite never fires inside a comment, a string literal or an
# inline "c++" body.
#
# Split out of private/port_dryrun.py, which carried all six transforms and
# this lexer in one file and wrote unconditionally because it ran on a
# throwaway copy of the tree. Each transform is now its own script, and each
# reports by default -- pass --apply to write.
import os, re, sys

IDENT = re.compile(r"[A-Za-z0-9_]")

OPEN  = "([{"
CLOSE = ")]}"


def code_mask(src):
    """[bool] per byte, True where the offset is Kairo code.

    Excluded: // and /// line comments, /* */ block comments, string literals
    (plain / r"" / f""), and `inline "c++" { ... }` bodies (raw C++).
    Included: f-string {...} interpolation regions, which contain real code.
    """
    n = len(src)
    mask = [True] * n
    i = 0
    while i < n:
        c = src[i]

        # line comment
        if c == "/" and i + 1 < n and src[i + 1] == "/":
            j = src.find("\n", i)
            j = n if j < 0 else j
            for k in range(i, j):
                mask[k] = False
            i = j
            continue

        # block comment
        if c == "/" and i + 1 < n and src[i + 1] == "*":
            j = src.find("*/", i + 2)
            j = n if j < 0 else j + 2
            for k in range(i, j):
                mask[k] = False
            i = j
            continue

        # inline "c++" { ... }  -> raw C++, skip the whole balanced body
        if src.startswith("inline", i) and mask[i]:
            m = re.match(r'inline\s+"c\+\+"\s*\{', src[i:])
            if m:
                start = i
                j = i + m.end() - 1  # at the '{'
                depth = 0
                while j < n:
                    if src[j] == "{":
                        depth += 1
                    elif src[j] == "}":
                        depth -= 1
                        if depth == 0:
                            j += 1
                            break
                    j += 1
                for k in range(start, min(j, n)):
                    mask[k] = False
                i = j
                continue

        # string literal (plain, r"", f"")
        if c == '"' or (c in "rf" and i + 1 < n and src[i + 1] == '"'):
            is_f = c == "f"
            start = i
            if c in "rf":
                i += 1
            i += 1  # past opening quote
            while i < n:
                if src[i] == "\\":
                    i += 2
                    continue
                if src[i] == '"':
                    i += 1
                    break
                # f-string interpolation: {...} is code
                if is_f and src[i] == "{":
                    depth = 0
                    j = i
                    while j < n:
                        if src[j] == "{":
                            depth += 1
                        elif src[j] == "}":
                            depth -= 1
                            if depth == 0:
                                j += 1
                                break
                        j += 1
                    # mark quote-to-brace as non-code, leave interior as code
                    for k in range(start, i + 1):
                        mask[k] = False
                    start = j - 1  # resume non-code marking at the closing }
                    i = j
                    continue
                i += 1
            for k in range(start, min(i, n)):
                mask[k] = False
            continue

        i += 1
    return mask


def interp_spans(src, mask):
    """Interior spans of f-string {...} interpolations.

    Operand scanning must never cross these boundaries: in
    f"{a}{b if c else d}" the `b` operand cannot reach back into `{a}`.
    """
    spans = []
    n = len(src)
    i = 0
    while i < n:
        if src[i] == "f" and i + 1 < n and src[i + 1] == '"' and not mask[i]:
            j = i + 2
            while j < n:
                if src[j] == "\\":
                    j += 2
                    continue
                if src[j] == '"':
                    j += 1
                    break
                if src[j] == "{":
                    depth = 0
                    k = j
                    while k < n:
                        if src[k] == "{":
                            depth += 1
                        elif src[k] == "}":
                            depth -= 1
                            if depth == 0:
                                break
                        k += 1
                    spans.append((j + 1, k))
                    j = k + 1
                    continue
                j += 1
            i = j
            continue
        i += 1
    return spans


def clamp(spans, pos):
    """(lo, hi) bounds for scanning around pos, or (None, None)."""
    for s, e in spans:
        if s <= pos < e:
            return s, e
    return None, None


def kw_at(src, mask, pos, word):
    """True if `word` starts at pos, is a whole token, and is in code."""
    if not src.startswith(word, pos) or not mask[pos]:
        return False
    if pos > 0 and IDENT.match(src[pos - 1]):
        return False
    e = pos + len(word)
    if e < len(src) and IDENT.match(src[e]):
        return False
    return all(mask[k] for k in range(pos, e))


def scan_to(src, mask, start, stops, stop_words=()):
    """Scan right from start until a stop char at depth 0 (or depth underflow)."""
    i = start
    depth = 0
    n = len(src)
    while i < n:
        c = src[i]
        if not mask[i]:
            i += 1
            continue
        if c in OPEN:
            depth += 1
        elif c in CLOSE:
            if depth == 0:
                return i
            depth -= 1
        elif depth == 0:
            if c in stops:
                return i
            for w in stop_words:
                if kw_at(src, mask, i, w):
                    return i
        i += 1
    return n


def masked_hits(src, pattern):
    """Every match of `pattern` that lies wholly in code, left to right."""
    mask = code_mask(src)
    return [m for m in re.finditer(pattern, src)
            if all(mask[k] for k in range(m.start(), m.end()))]


# --------------------------------------------------------------------------
# CLI driver. Every script in this folder is:
#
#     from kairo_lex import run
#     def rewrite(src, path, report) -> (src, count)
#     run(rewrite, "<one-line description>")
#
# Report by default; --apply writes. --only SUBSTR narrows to paths containing
# SUBSTR. Skips trees that are C++ by design.
# --------------------------------------------------------------------------
SKIP_DIR = ("/Native/", "/bootstrap/", "/llvm-runtimes/", "/build/", "/.git/")


def walk(root, only=None):
    out = []
    for dirpath, _, names in os.walk(root):
        for nm in sorted(names):
            if not nm.endswith(".k"):
                continue
            p = os.path.join(dirpath, nm)
            if any(d in p for d in SKIP_DIR):
                continue
            if only and only not in p:
                continue
            out.append(p)
    return sorted(out)


def run(rewrite, what):
    args = sys.argv[1:]
    if not args:
        print(f"usage: {os.path.basename(sys.argv[0])} <root> [--apply] [--only SUBSTR]")
        print(f"       {what}")
        return 2
    root = args[0]
    apply = "--apply" in args
    only = args[args.index("--only") + 1] if "--only" in args else None

    files = walk(root, only)
    report = []
    total = changed = 0

    for path in files:
        with open(path, "r", encoding="utf-8") as fh:
            src = fh.read()
        new, n = rewrite(src, os.path.relpath(path, root), report)
        if not n:
            continue
        total += n
        changed += 1
        print(f"{n:5d} {path}")
        if apply and new != src:
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(new)

    print(f"\n{what}")
    print(f"{total} site(s) in {changed} file(s) of {len(files)} scanned")
    if report:
        print(f"\nSKIPPED ({len(report)}) -- by hand:")
        for r in report:
            print("  " + r)
    if not apply:
        print("\n(report only -- pass --apply to rewrite)")
    return 0
