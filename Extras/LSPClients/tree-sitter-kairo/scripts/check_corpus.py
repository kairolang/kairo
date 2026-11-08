#!/usr/bin/env python3
"""Parse every .k file under a Kairo checkout with this grammar and report.

usage: scripts/check_corpus.py <kairo-repo> [--split]

Tests are split by their lit check lines: a test whose non-NOT check lines
expect a syntax/lexer/preprocessor error (`error [S..`, `error [L..`,
`error [P..`, or a bare `error`) is NEGATIVE; everything else is POSITIVE and
must parse with no ERROR / MISSING node. Tests/Manual (scratch files, no RUN
lines) is skipped.

--split also reports same-line sibling statements with no `;` between them
where the first does not end in `}`: legal Kairo (terminators are optional),
but the usual symptom of the grammar ending a statement early.

Needs: pip install tree-sitter; `tree-sitter generate` already run; gcc.
"""
import ctypes, os, re, subprocess, sys, time, warnings

warnings.simplefilter("ignore")
from tree_sitter import Language, Parser  # noqa: E402

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SO = os.path.join(HERE, "kairo.so")
CHECK = re.compile(r"^\s*//\s*([A-Z][A-Z0-9_-]*):(.*)$")
SYNTAX_ERR = re.compile(r"error \[(S|L|P)|\berror\b(?! \[[A-Z])")
LISTS = {"source_file", "block", "declaration_list"}


def build():
    src = os.path.join(HERE, "src")
    if not os.path.exists(os.path.join(src, "parser.c")):
        subprocess.check_call(["tree-sitter", "generate"], cwd=HERE)
    subprocess.check_call(["gcc", "-O2", "-shared", "-fPIC", "-I", src,
                           os.path.join(src, "parser.c"), os.path.join(src, "scanner.c"), "-o", SO])
    lib = ctypes.cdll.LoadLibrary(SO)
    lib.tree_sitter_kairo.restype = ctypes.c_void_p
    return Parser(Language(lib.tree_sitter_kairo()))


def is_negative(path):
    for line in open(path, errors="replace"):
        m = CHECK.match(line)
        if m and not m.group(1).endswith("NOT") and SYNTAX_ERR.search(m.group(2)):
            return True
    return False


def first_error(n):
    if n.is_error or n.is_missing:
        return n
    for c in n.children:
        if c.has_error or c.is_error or c.is_missing:
            r = first_error(c)
            if r:
                return r
    return None


def splits(tree, src):
    out, stack = [], [tree.root_node]
    while stack:
        n = stack.pop()
        stack.extend(n.children)
        if n.type not in LISTS:
            continue
        kids = [c for c in n.children if c.is_named and "comment" not in c.type]
        for a, b in zip(kids, kids[1:]):
            if a.end_point[0] != b.start_point[0]:
                continue
            if src[a.start_byte:a.end_byte].rstrip().endswith((b"}", b";")) or b";" in src[a.end_byte:b.start_byte]:
                continue
            out.append((a.end_point[0] + 1, a.type, b.type))
    return out


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    repo, want_split = sys.argv[1], "--split" in sys.argv
    parser = build()
    groups = {"Tests (positive)": [], "Tests (negative)": [], "Compiler/Lib/Extras sources": []}
    for d, _, fs in os.walk(repo):
        if "/.git" in d or "/Tests/Manual" in d:
            continue
        for f in fs:
            if not f.endswith(".k"):
                continue
            p = os.path.join(d, f)
            if "/Tests/" in p:
                groups["Tests (negative)" if is_negative(p) else "Tests (positive)"].append(p)
            else:
                groups["Compiler/Lib/Extras sources"].append(p)

    for name, files in groups.items():
        bad, split_hits, t_total = [], [], 0.0
        for p in sorted(files):
            src = open(p, "rb").read()
            t0 = time.time()
            tree = parser.parse(src, progress_callback=lambda _s: time.time() - t0 > 5)
            t_total += time.time() - t0
            if tree is None:
                bad.append((p, 0, "TIMEOUT", ""))
                continue
            if tree.root_node.has_error:
                e = first_error(tree.root_node) or tree.root_node
                text = e.text.decode(errors="replace").replace("\n", "\\n")[:80]
                bad.append((p, e.start_point[0] + 1, "MISSING " + e.type if e.is_missing else e.type, text))
            elif want_split and name != "Tests (negative)":
                split_hits += [(p, *s) for s in splits(tree, src)]
        clean = len(files) - len(bad)
        print(f"{name}: {clean}/{len(files)} parse clean  ({t_total:.2f}s)")
        if name != "Tests (negative)":
            for p, line, kind, text in bad:
                print(f"  {os.path.relpath(p, repo)}:{line}: [{kind}] {text}")
            for p, line, a, b in split_hits:
                print(f"  split {os.path.relpath(p, repo)}:{line}: {a} | {b}")


if __name__ == "__main__":
    main()
