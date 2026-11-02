#!/usr/bin/env python3
# Ground truth for cpp_casts.py: what clang says every Stage 0 C++ cast is.
#
# The right Stage 1 spelling of `static_cast::<T>(x)` depends on the operand's
# TYPE -- an enum takes `x as U as T`, a pointer to a base is an offset
# adjustment, an integer into a closed enum is a checked cast that crashes --
# and no lexer knows types. clang does: it compiles the very C++ Stage 0 emits
# for the tree and names each cast's kind (IntegralCast, DerivedToBase, ...).
# This script produces that table; cpp_casts.py consumes it.
#
#   1. Stage 0 compiles the entry file. Its real output (the cache .cxx it
#      hands clang, not --emit-ir, which is one token per line and breaks
#      every preprocessor directive) carries `#line N __$FILE_k__` markers
#      back to the .k files. Its own compile command names that file, so a
#      flag clang rejects stops it right there, with the file written.
#   2. The #line markers are turned into comments, keeping the line count,
#      and the mapping physical-line -> (.k file, line) is kept here instead.
#      With the markers live, clang would print .k locations whose columns
#      are .cxx columns and whose lines repeat across physical lines, so two
#      different casts could share one location and dedup would merge them.
#   3. `clang -fsyntax-only -Xclang -ast-dump` is STREAMED (2 GB for
#      Compiler/) and only the cast nodes, their operand chain and the
#      enum / namespace / record declarations are kept. Locations in the
#      text dump are relative to the previous one printed (`line:` / `col:`),
#      so every location token before a node's type is replayed in order.
#   4. A cast in a template is dumped once for the pattern and once per
#      instantiation, at one location. Sites are keyed by that location and
#      every instance's kind is kept: cpp_casts.py rewrites only when all of
#      them agree.
#
#   python3 Scripts/Migration/cast_facts.py --out FACTS.json [--root .]
#       [--entry Compiler/Driver/Kairo.k] [--cxx STAGE0.cxx] [--keep DIR]
#
# Run it on the tree the copy was made FROM (the Stage 0 tree), before any
# migration touches the copy. It never writes into the tree.
import json, os, re, shlex, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.realpath(os.path.join(HERE, "..", ".."))

CAST_NODES = {
    "CXXStaticCastExpr": "static_cast",
    "CXXReinterpretCastExpr": "reinterpret_cast",
    "CXXConstCastExpr": "const_cast",
}

# Same -I set kbld gives the kairo target (build.k: kairo_inc + llvm_includes).
INCLUDES = ["Compiler", "Lib/bootstrap/lib-helix/core", "Extras/KaTAR", "Linker", "."]
LLVM_INCLUDES = ["build/llvm/include", "Lib/llvm-runtimes/llvm/include",
                 "Lib/llvm-runtimes/lld/include", "Lib/llvm-runtimes/clang/include",
                 "build/llvm/tools/clang/include"]


def stage0_cxx(root, entry, keep):
    """Run Stage 0 far enough to write its .cxx; return a copy's path."""
    cmd = ["kairo", entry] + ["-I" + i for i in INCLUDES] + \
          ["--verbose", "-o", os.path.join(keep, "stage0.out"), "--", "--cast-facts-stop-here"]
    p = subprocess.run(cmd, cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    out = p.stdout.decode("utf-8", "replace")
    m = None
    for line in out.splitlines():
        if "compile command:" in line:
            m = line
    if m is None:
        sys.exit("cast_facts: Stage 0 printed no compile command; did it fail to parse?\n" + out[-4000:])
    words = shlex.split(m.split("compile command:", 1)[1])
    cxx = [w for w in words if w.endswith(".cxx")]
    if not cxx:
        sys.exit("cast_facts: no .cxx in Stage 0's compile command:\n" + m)
    flags = []
    i = 0
    while i < len(words):
        if words[i] in ("-include", "-I") and i + 1 < len(words):
            flags += [words[i], words[i + 1]]
            i += 2
            continue
        i += 1
    dst = os.path.join(keep, "stage0.cxx")
    shutil.copyfile(cxx[-1], dst)
    with open(dst + ".flags", "w", encoding="utf-8") as fh:
        json.dump(flags, fh)
    return dst, flags


def strip_lines(cxx, out):
    """#line markers -> comments; returns {phys_line: (file, presumed)} as two
    arrays indexed by physical line (1-based), and the file table."""
    files = {}
    with open(cxx, encoding="utf-8", errors="replace") as fh:
        lines = fh.read().split("\n")
    fid = [None] * (len(lines) + 2)
    pres = [0] * (len(lines) + 2)
    cur_f, cur_l = None, 0
    define = re.compile(r'^#define (__\$FILE_\d+__) "(.*)"\s*$')
    marker = re.compile(r'^#line (\d+)(?: (\S+))?\s*$')
    for i, ln in enumerate(lines, 1):
        m = define.match(ln)
        if m:
            files[m.group(1)] = m.group(2)
        m = marker.match(ln)
        if m:
            cur_l = int(m.group(1)) - 1   # the NEXT physical line is line N
            if m.group(2):
                cur_f = files.get(m.group(2), m.group(2).strip('"'))
            lines[i - 1] = "// " + ln
            fid[i] = None
            continue
        cur_l += 1
        fid[i] = cur_f
        pres[i] = cur_l
    with open(out, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))
    return lines, fid, pres


LOC = re.compile(r"(/[^\s<>,:]+|<built-in>|<scratch space>):(\d+):(\d+)|line:(\d+):(\d+)|col:(\d+)")
QUOTED = re.compile(r"'([^']*)'(?::'([^']*)')?")
KIND = re.compile(r" <([A-Za-z]+)(?: \((.*)\))?>( part_of_explicit_cast)?\s*$")
NODE = re.compile(r"^([|`\- ]*)(\w+)")


def parse_dump(stream, main_file):
    """Stream the text dump; return (sites, enums)."""
    sites = {}
    enums = {}
    stack = []                      # (indent, name) of enclosing ns / records
    lf, ll = None, 0                # clang's LastLocFilename / LastLocLine
    chain = None                    # [site-record, expect_indent] while reading an operand chain
    for raw in stream:
        line = raw.decode("utf-8", "replace").rstrip("\n")
        q = line.find("'")
        prefix = line if q < 0 else line[:q]
        begin = None
        last = None
        for m in LOC.finditer(prefix):
            if m.group(1):
                lf, ll, c = m.group(1), int(m.group(2)), int(m.group(3))
            elif m.group(4):
                ll, c = int(m.group(4)), int(m.group(5))
            else:
                c = int(m.group(6))
            if begin is None:
                begin = (lf, ll, c)
            last = (lf, ll, c)
        nm = NODE.match(line)
        if not nm:
            continue
        indent, node = len(nm.group(1)), nm.group(2)

        if chain is not None:
            rec, want = chain
            chain = None
            if indent == want:
                ty = QUOTED.search(line[len(nm.group(0)):])
                rec["op"] = [ty.group(1), ty.group(2) or ty.group(1)] if ty else None
                rec["op_node"] = node
                if "part_of_explicit_cast" in line:
                    # One step of the cast itself: clang spells
                    # static_cast<B *>(d) as a NoOp over an implicit
                    # DerivedToBase, and an int widening as a NoOp over an
                    # IntegralCast. The operand is the node below the chain.
                    km = KIND.search(line)
                    rec["chain"].append(km.group(1) if km else None)
                    chain = [rec, indent + 2]

        if node in CAST_NODES and begin is not None and begin[0] == main_file:
            rest = line[len(nm.group(0)):]
            ty = QUOTED.search(rest)
            km = KIND.search(line)
            rec = {"kind": km.group(1) if km else None,
                   "path": km.group(2) if km else None,
                   "tgt": [ty.group(1), ty.group(2) or ty.group(1)] if ty else None,
                   "op": None, "op_node": None, "chain": []}
            key = (begin[1], begin[2])
            s = sites.setdefault(key, {"kw": CAST_NODES[node], "inst": []})
            s["inst"].append(rec)
            chain = [rec, indent + 2]
            continue

        if node.endswith("Decl") and stack and stack[-1][0] >= indent:
            # Any sibling declaration closes the scopes above it -- a
            # ClassTemplateDecl or FunctionDecl included, which push none.
            while stack and stack[-1][0] >= indent:
                stack.pop()
        if node in ("NamespaceDecl", "CXXRecordDecl", "EnumDecl", "ClassTemplateSpecializationDecl"):
            # The CXXRecordDecl a record names inside itself is implicit,
            # and a ClassTemplateDecl's pattern is its CXXRecordDecl child:
            # neither may add a second level of the same name.
            if node == "CXXRecordDecl" and " implicit " in prefix:
                continue
            while stack and stack[-1][0] >= indent:
                stack.pop()
            tail = re.sub(r"0x[0-9a-f]+", " ", prefix)
            tail = re.sub(r"<[^<>]*(?:<[^<>]*>[^<>]*)*>", " ", tail)   # the source range
            mk = re.search(r"\b(?:class|struct|union|enum)\s+([A-Za-z_$][\w$]*)", tail)
            words = [w for w in tail.split() if not re.match(r"(col|line):\d|/|prev$|parent$|used$|referenced$|implicit$|invalid$", w)]
            if mk:
                name = mk.group(1)
            elif node != "NamespaceDecl" and words and re.match(r"[A-Za-z_$][\w$]*$", words[-1]) and words[-1] not in ("definition", node):
                name = words[-1]
            elif node == "NamespaceDecl" and len(words) > 1 and re.match(r"[A-Za-z_$][\w$]*$", words[-1]) and words[-1] != "inline":
                name = words[-1]
            else:
                name = "(anonymous namespace)" if node == "NamespaceDecl" else "(anonymous)"
            stack.append((indent, name))
            if node == "EnumDecl" and last is not None and last[0] == main_file:
                qn = "::".join(n for _, n in stack)
                ty = QUOTED.search(line[len(nm.group(0)):])
                enums[qn] = {"name": name, "loc": [last[1], last[2]],
                             "underlying": [ty.group(1), ty.group(2) or ty.group(1)] if ty else None}
    return sites, enums


def main():
    a = sys.argv[1:]

    def opt(f, d=None):
        return a[a.index(f) + 1] if f in a else d
    out = opt("--out")
    if not out:
        print(__doc__ or "usage: cast_facts.py --out FACTS.json [--root R] [--entry E] [--cxx F] [--keep DIR]")
        return 2
    root = os.path.realpath(opt("--root", REPO))
    entry = opt("--entry", "Compiler/Driver/Kairo.k")
    keep = opt("--keep") or tempfile.mkdtemp(prefix="cast_facts.")
    os.makedirs(keep, exist_ok=True)
    clang = opt("--clang", os.path.join(root, "build/llvm/bin/clang++"))

    if opt("--cxx"):
        # Re-running on a .cxx an earlier run kept: its Stage 0 flags (the
        # core.hh prelude) were saved beside it.
        cxx = opt("--cxx")
        try:
            with open(cxx + ".flags", encoding="utf-8") as fh:
                flags = json.load(fh)
        except OSError:
            sys.exit(f"cast_facts: {cxx}.flags not found; --cxx takes a .cxx an earlier run kept with --keep")
    else:
        print("cast_facts: Stage 0 ->", entry, file=sys.stderr)
        cxx, flags = stage0_cxx(root, entry, keep)
    stripped = os.path.join(keep, "stage0.stripped.cxx")
    lines, fid, pres = strip_lines(cxx, stripped)

    cmd = [clang, "-fsyntax-only", "-Xclang", "-ast-dump", "-fno-color-diagnostics", "-w",
           "-xc++", "-std=c++23", "-fexceptions", "-stdlib=libc++",
           "-DNOMINMAX", "-DCLANG_BUILD_STATIC", '-DVERSION="cast-facts"'] + flags
    cmd += ["-I" + os.path.join(root, i) for i in INCLUDES + LLVM_INCLUDES]
    cmd += [stripped]
    print("cast_facts: clang -ast-dump (streamed) ...", file=sys.stderr)
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    sites, enums = parse_dump(p.stdout, stripped)
    err = p.stderr.read().decode("utf-8", "replace")
    p.wait()
    errors = [l for l in err.splitlines() if " error: " in l]

    out_sites = []
    for (pl, pc), s in sorted(sites.items()):
        text = lines[pl - 1] if 0 < pl <= len(lines) else ""
        at = text[pc - 1:]
        # Stage 0 separates every token by two spaces; inline C++ is verbatim.
        stage0 = bool(re.match(r"(static|reinterpret|const)_cast  <  ", at))
        written = None
        if stage0:
            depth, j = 0, at.index("<")
            k = j
            while k < len(at):
                if at[k] == "<":
                    depth += 1
                elif at[k] == ">":
                    depth -= 1
                    if depth == 0:
                        break
                k += 1
            written = " ".join(at[j + 1:k].split())
        # Stage 0's own `op as` dispatch: `operator$cast(static_cast<T *>(nullptr))`
        # tags the overload by type and has no counterpart in the .k source.
        synth = stage0 and bool(re.search(r"operator\$cast  \(  $", text[:pc - 1])) \
            and bool(re.match(r"[a-z_]+  <  .*?  >  \(  nullptr  \)", at))
        out_sites.append({"file": fid[pl], "line": pres[pl], "pline": pl, "pcol": pc,
                          "kw": s["kw"], "stage0": stage0 and not synth, "synth": synth, "written": written,
                          "inst": s["inst"]})
    enum_out = {}
    for qn, e in enums.items():
        pl = e["loc"][0]
        enum_out[qn] = dict(e, file=fid[pl], line=pres[pl])
    # The width a pointer -> integer cast must keep, from the clang that
    # classified the casts (the host Stage 0 built for), not assumed.
    pm = subprocess.run([clang, "-dM", "-E", "-xc++", os.devnull], stdout=subprocess.PIPE)
    m = re.search(rb"#define __SIZEOF_POINTER__ (\d+)", pm.stdout)
    pointer_bits = int(m.group(1)) * 8 if m else None
    facts = {"root": root, "entry": entry, "pointer_bits": pointer_bits, "clang_errors": errors[:50],
             "sites": out_sites, "enums": enum_out}
    with open(out, "w", encoding="utf-8") as fh:
        json.dump(facts, fh)
    n0 = sum(1 for s in out_sites if s["stage0"])
    print(f"cast_facts: {len(out_sites)} cast sites ({n0} from Kairo code, "
          f"{len(out_sites) - n0} verbatim C++), {len(enum_out)} enums, "
          f"{len(errors)} clang error(s) -> {out}", file=sys.stderr)
    if errors:
        print("cast_facts: clang errors (a site in a broken body may be missing):", file=sys.stderr)
        for e in errors[:10]:
            print("  " + e, file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
