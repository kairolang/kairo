#!/usr/bin/env python3
# The API surface Compiler/ uses of Stage 0's runtime string and containers:
# every member call, operator and constructor clang sees on string / vec /
# map / set / unordered_map in the C++ Stage 0 emits, with its .k sites --
# typed, from clang's AST, not a text search. Reuses cast_facts.py's Stage 0
# driver, #line stripping and location replay. Read-only: it writes only into
# KEEP_DIR. What Stage 1's builtin string and containers must provide for
# Compiler/ to self-host.
#
#   python3 Scripts/Migration/api_surface.py <keep-dir>
import json, os, re, subprocess, sys, collections
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cast_facts as cf

ROOT = cf.REPO
if len(sys.argv) < 2:
    sys.exit("usage: api_surface.py KEEP_DIR   (writes KEEP_DIR/api.json; reuses a stage0.cxx kept there)")
KEEP = sys.argv[1]
os.makedirs(KEEP, exist_ok=True)
cxx = os.path.join(KEEP, "stage0.cxx")
if os.path.exists(cxx) and os.path.exists(cxx + ".flags"):
    flags = json.load(open(cxx + ".flags"))
else:
    cxx, flags = cf.stage0_cxx(ROOT, "Compiler/Driver/Kairo.k", KEEP)
stripped = os.path.join(KEEP, "stage0.stripped.cxx")
lines, fid, pres = cf.strip_lines(cxx, stripped)

def family(t):
    t = t.strip()
    for q in ("const ", "volatile ", "struct ", "class "):
        if t.startswith(q): t = t[len(q):]
    t = t.rstrip("&* ").strip()
    if t.endswith(" const"): t = t[:-6].rstrip("&* ")
    head = t.split("<", 1)[0].strip()
    if head in ("string", "kairo::std::String::basic", "std::String::basic") and t.endswith("<unsigned char>") or head == "string": return "string"
    if head in ("vec", "std::vector", "std::__1::vector", "kairo::libcxx::vector"): return "vec"
    if head in ("std::unordered_map", "std::__1::unordered_map"): return "unordered_map"
    if head in ("map", "std::map", "std::__1::map", "kairo::libcxx::map"): return "map"
    if head in ("set", "std::set", "std::__1::set", "kairo::libcxx::set"): return "set"
    return None

cmd = [os.path.join(ROOT, "build/llvm/bin/clang++"), "-fsyntax-only", "-Xclang", "-ast-dump",
       "-fno-color-diagnostics", "-w", "-xc++", "-std=c++23", "-fexceptions", "-stdlib=libc++",
       "-DNOMINMAX", "-DCLANG_BUILD_STATIC", '-DVERSION="api"'] + flags
cmd += ["-I" + os.path.join(ROOT, i) for i in cf.INCLUDES + cf.LLVM_INCLUDES] + [stripped]
p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)

uses = collections.defaultdict(lambda: {"n": 0, "sites": []})
lf, ll = None, 0
pending = None        # (kind, name, loc, want_indent)
opst = None           # [indent, name, children_seen, loc]
for raw in p.stdout:
    line = raw.decode("utf-8", "replace").rstrip("\n")
    q = line.find("'"); prefix = line if q < 0 else line[:q]
    begin = None
    for m in cf.LOC.finditer(prefix):
        if m.group(1): lf, ll, c = m.group(1), int(m.group(2)), int(m.group(3))
        elif m.group(4): ll, c = int(m.group(4)), int(m.group(5))
        else: c = int(m.group(6))
        if begin is None: begin = (lf, ll, c)
    nm = cf.NODE.match(line)
    if not nm: continue
    indent, node = len(nm.group(1)), nm.group(2)
    rest = line[len(nm.group(0)):]
    if opst is not None:
        if indent <= opst[0]:
            opst = None
        else:
            if node == "DeclRefExpr" and opst[1] is None:
                mo = re.search(r"'(operator[^']*)'", rest)
                if mo: opst[1] = mo.group(1)
            if indent == opst[0] + 2:
                opst[2] += 1
                if opst[2] == 2:
                    ty = cf.QUOTED.search(rest)
                    fam = family((ty.group(2) or ty.group(1))) if ty else None
                    if fam and opst[1]:
                        k = (fam, "operator", opst[1]); uses[k]["n"] += 1
                        if len(uses[k]["sites"]) < 6: uses[k]["sites"].append(opst[3])
    if pending is not None and indent == pending[3]:
        kind, name, loc, _ = pending; pending = None
        ty = cf.QUOTED.search(rest)
        if ty:
            fam = family(ty.group(2) or ty.group(1))
            if fam: 
                k = (fam, kind, name)
                uses[k]["n"] += 1
                if len(uses[k]["sites"]) < 6: uses[k]["sites"].append(loc)
    elif pending is not None and indent <= pending[3] - 2:
        pending = None
    if begin is None or begin[0] != stripped: continue
    pl = begin[1]
    kf = fid[pl] if pl < len(fid) else None
    if not kf or not kf.endswith(".k") or "/Compiler/" not in kf and "/Linker/" not in kf: continue
    loc = f"{os.path.relpath(kf, ROOT)}:{pres[pl]}"
    if node == "MemberExpr":
        mm = re.search(r"(?:\.|->)(~?[A-Za-z_]\w*|operator\S+)\s+0x", rest)
        if mm: pending = ("method", mm.group(1), loc, indent + 2)
    elif node == "CXXOperatorCallExpr":
        opst = [indent, None, 0, loc]
    elif node == "CXXConstructExpr":
        ty = cf.QUOTED.findall(rest)
        if len(ty) >= 2:
            fam = family(ty[0][1] or ty[0][0])
            if fam:
                k = (fam, "ctor", ty[1][0]); uses[k]["n"] += 1
                if len(uses[k]["sites"]) < 6: uses[k]["sites"].append(loc)
p.wait()
out = sorted(([f, k, n, v["n"], v["sites"]] for (f, k, n), v in uses.items()), key=lambda r: (r[0], -r[3]))
json.dump(out, open(os.path.join(KEEP, "api.json"), "w"), indent=0)
for f, k, n, cnt, s in out: print(f"{f:14} {k:8} {str(n)[:60]:60} {cnt:6}  {s[0] if s else ''}")
