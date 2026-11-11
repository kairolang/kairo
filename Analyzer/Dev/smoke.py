#!/usr/bin/env python3
"""End-to-end check of kals over stdio, on a project this script writes.

    python3 Analyzer/Dev/smoke.py [path/to/kals]

Default binary: the newest build/<triple>/{debug,release}/bin/kals. Exits 0
when every check passes; prints the failing check otherwise. It lives here and
not under Tests/ because that tree is frozen; it is the server's regression
test until a lit wrapper is approved.
"""
import glob, json, os, shutil, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lsp_client import Client

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

SHAPES = '''import std::io

/// A point in the plane.
pub class Point {
    pub var x: i32 = 0
    pub var y: i32 = 0

    /// Adds two points, member by member.
    pub fn op + (const self, const o: Point) -> Point {
        return Point { x: self.x + o.x, y: self.y + o.y }
    }

    pub fn norm1(const self) -> i32 {
        return self.x + self.y
    }
}

/// Describes an integer.
pub fn describe(v: i32) -> string {
    return f"int {v}"
}

/// Describes a point.
pub fn describe(const p: Point) -> string {
    return f"point {p.x},{p.y}"
}

pub fn tier(x: i32) -> i32 where x > 100 { return 2 }
pub fn tier(x: i32) -> i32 where x > 0 { return 1 }
pub fn tier(x: i32) -> i32 { return 0 }

pub enum Color derives u8 { Red, Green, Blue }

interface Add {
    fn op + (self, Self) -> Self
}

interface Sub {
    fn op - (self, Self) -> Self
}

interface Math derives Sub + Add { }

pub class Base {
    pub var id: i32 = 0

    pub fn label(const self) -> i32 {
        return self.id
    }
}

pub class Derived derives Base {
    pub var extra: i32 = 0

    pub fn label(const self) -> i32 {
        return self.extra
    }
}

pub class Crate {
    pub var v: i32 = 0

    pub fn Crate(self) = default

    pub fn Crate(self, v: i32) {
        self.v = v
    }
}

/// Nobody calls this yet.
pub fn unused_so_far(first: i32, second: string) -> i32 {
    return first
}

pub fn <T> wide(v: T) -> i32 requires sizeof(T) > 4 { return 1 }

pub struct Pair {
    pub var a: i32
    pub var b: i64
}

extend Base {
    pub fn doubled(const self) -> i32 {
        return self.id * 2
    }
}

pub fn use_ext(const b: Base) -> i32 {
    return b.doubled()
}

pub enum Level { Low = 1, Mid, High = 10 }

pub enum Shape { Circle { r: f64 }, Rect { w: f64, h: f64 }, Empty }

pub union Bits {
    var as_u32: u32
    var as_f32: f32
}
'''

MAIN = '''import std::io
import shapes::{
    Color,
    Point,
    describe,
    tier,
    wide,
}

const LIMIT: i32 = 10

fn clamp(v: i32) -> i32 {
    if v > LIMIT {
        return LIMIT
    }

    return v
}

fn main() -> i32 {
    var a = Point { x: 1, y: 2 }
    var b = Point { x: 3, y: 4 }
    var c = a + b
    var n = clamp(c.norm1())
    io::println(describe(n))
    io::println(describe(c))
    var t = tier(n)
    var w = wide(7 as i64)
    var col = Color::Green
    return 0
}
'''

TYPES = ["namespace", "type", "class", "enum", "interface", "struct", "typeParameter", "parameter", "variable",
         "property", "enumMember", "function", "method", "macro", "keyword", "comment", "string", "number", "operator",
         "selfKeyword", "builtinType", "typeAlias", "union"]
MODS = ["declaration", "definition", "readonly", "static", "deprecated", "abstract", "async", "modification",
        "documentation", "defaultLibrary", "overloaded", "dispatched", "unsafe", "ffi", "constant", "constructor",
        "extension", "mutates", "mutable", "panics"]

KEYWORDS = {"fn", "var", "return", "import", "const", "if", "as", "pub", "class", "else", "while", "for", "macro"}

failures = []


def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else "  -- " + str(detail)[:400]))
    if not cond:
        failures.append(name)


def find_kals():
    if len(sys.argv) > 1:
        return os.path.abspath(sys.argv[1])
    c = [p for p in glob.glob(os.path.join(ROOT, "build", "*", "*", "bin", "kals")) if os.access(p, os.X_OK)]
    if not c:
        sys.exit("no kals binary; build one with: python3 build.py --debug kals")
    return max(c, key=os.path.getmtime)


def project(base):
    os.makedirs(os.path.join(base, "src"))
    open(os.path.join(base, "src", "shapes.k"), "w").write(SHAPES)
    open(os.path.join(base, "src", "main.k"), "w").write(MAIN)
    open(os.path.join(base, "kairo_compile.json"), "w").write(
        '{ "version": 1, "entries": [ { "entry": "src/main.k", "args": ["-I", "src"] } ] }\n')


def decode(data, text):
    """Semantic token data -> [(line, col, word, type, {mods})]."""
    lines, out, l, c = text.split("\n"), [], 0, 0
    for i in range(0, len(data), 5):
        if data[i]:
            l, c = l + data[i], data[i + 1]
        else:
            c += data[i + 1]
        out.append((l, c, lines[l][c:c + data[i + 2]], TYPES[data[i + 3]], {MODS[b] for b in range(len(MODS)) if data[i + 4] >> b & 1}))
    return out


def pos(text, needle, off=0, nth=0):
    k = -1
    for i, l in enumerate(text.split("\n")):
        j = l.find(needle)
        if j >= 0:
            k += 1
            if k == nth:
                return i, j + off
    raise KeyError(needle)


def tokens(c, rel, text):
    r = c.request("textDocument/semanticTokens/full", {"textDocument": {"uri": c.uri(rel)}})
    return decode(r["data"], text)


def features(exe, root, label):
    c = Client(exe, root)
    caps = c.start()["capabilities"]
    check(label + "capabilities", all(k in caps for k in (
        "semanticTokensProvider", "definitionProvider", "completionProvider", "codeActionProvider",
        "documentFormattingProvider", "hoverProvider", "referencesProvider", "renameProvider")), caps.keys())
    M = "src/main.k"
    src = c.open(M)

    # --- semantic highlighting, with the overload and where-dispatch marks
    t = tokens(c, M, src)
    by = {(l, col): (w, ty, m) for l, col, w, ty, m in t}
    def tok(needle, off=0, nth=0):
        return by.get(pos(src, needle, off, nth), ("", "", set()))
    check(label + "tokens: class use", tok("Point {")[1] == "class", tok("Point {"))
    check(label + "tokens: constant", tok("LIMIT {", 0)[1] == "variable" and "readonly" in tok("LIMIT {")[2], tok("LIMIT {"))
    check(label + "tokens: method", tok("norm1")[1] == "method", tok("norm1"))
    check(label + "tokens: enum member", tok("Green")[1] == "enumMember", tok("Green"))
    check(label + "tokens: namespace", tok("io::println")[1] == "namespace", tok("io::println"))
    check(label + "tokens: overloaded function call", "overloaded" in tok("describe(n)")[2], tok("describe(n)"))
    check(label + "tokens: user operator is an overloaded operator",
          tok("a + b", 2)[1] == "operator" and "overloaded" in tok("a + b", 2)[2], tok("a + b", 2))
    check(label + "tokens: where-dispatched call", "dispatched" in tok("tier(n)")[2], tok("tier(n)"))
    check(label + "tokens: plain call is not marked", not ({"overloaded", "dispatched"} & tok("clamp(c")[2]), tok("clamp(c"))

    # --- jump, hover, highlight, references, rename, outline, inlay
    d = c.request("textDocument/definition", c.at(M, *pos(src, "describe(c)")))
    check(label + "definition: picks the chosen overload", d and d["uri"].endswith("shapes.k") and d["range"]["start"]["line"] == pos(SHAPES, "fn describe(const p")[0], d)
    d = c.request("textDocument/definition", c.at(M, *pos(src, "a + b", 2)))
    check(label + "definition: operator -> op fn", d and d["range"]["start"]["line"] == pos(SHAPES, "fn op +")[0], d)
    h = c.request("textDocument/hover", c.at(M, *pos(src, "describe(n)")))
    check(label + "hover: signature and doc", h and "fn describe(v: i32) -> string" in h["contents"]["value"] and "Describes an integer." in h["contents"]["value"], h)
    h = c.request("textDocument/hover", c.at(M, *pos(src, "var c", 4)))
    check(label + "hover: inferred type", h and "var c: Point" in h["contents"]["value"], h)
    hl = c.request("textDocument/documentHighlight", c.at(M, *pos(src, "var c", 4)))
    check(label + "highlight", len(hl) == 3, hl)
    refs = c.request("textDocument/references", dict(c.at(M, *pos(src, "Point {")), context={"includeDeclaration": True}))
    check(label + "references: across files", {r["uri"].split("/")[-1] for r in refs} == {"main.k", "shapes.k"}, refs)
    rn = c.request("textDocument/rename", dict(c.at(M, *pos(src, "clamp")), newName="clamp2"))
    check(label + "rename", rn and sum(len(v) for v in rn["changes"].values()) == 2, rn)
    sy = c.request("textDocument/documentSymbol", {"textDocument": {"uri": c.uri(M)}})
    check(label + "outline", [s["name"] for s in sy] == ["LIMIT", "clamp", "main"], sy)
    ih = c.request("textDocument/inlayHint", {"textDocument": {"uri": c.uri(M)}, "range": {}})
    check(label + "inlay hints", ": Point" in [x["label"] for x in ih] and ": i32" in [x["label"] for x in ih], ih)
    check(label + "diagnostics: clean file is clean", not c.diagnostics(M), c.diagnostics(M))

    # --- the providers answered from one row or from the text
    check(label + "capabilities: second set", all(k in caps for k in (
        "signatureHelpProvider", "typeDefinitionProvider", "declarationProvider", "workspaceSymbolProvider",
        "foldingRangeProvider", "selectionRangeProvider", "documentLinkProvider")), caps.keys())
    td = c.request("textDocument/typeDefinition", c.at(M, *pos(src, "var c", 4)))
    check(label + "type definition: variable -> its class", td and td["uri"].endswith("shapes.k") and td["range"]["start"]["line"] == pos(SHAPES, "class Point")[0], td)
    td = c.request("textDocument/typeDefinition", c.at(M, *pos(src, "LIMIT {")))
    check(label + "type definition: none for a builtin type", td is None, td)
    dc = c.request("textDocument/declaration", c.at(M, *pos(src, "clamp(c")))
    check(label + "declaration", dc and dc["range"]["start"]["line"] == pos(src, "fn clamp")[0], dc)
    pr = c.request("textDocument/prepareRename", c.at(M, *pos(src, "clamp(c")))
    check(label + "prepareRename: a resolved name", pr and pr["start"]["character"] == pos(src, "clamp(c")[1], pr)
    pr = c.request("textDocument/prepareRename", c.at(M, *pos(src, "return 0")))
    check(label + "prepareRename: refuses a keyword", pr is None, pr)
    ln = c.request("textDocument/documentLink", {"textDocument": {"uri": c.uri(M)}})
    check(label + "document links: imports", any(x["target"].endswith("shapes.k") for x in ln) and any(x["target"].endswith("io.k") for x in ln), ln)
    ws = c.request("workspace/symbol", {"query": "desc"})
    check(label + "workspace symbols", {x["name"] for x in ws} == {"describe"} and all(x["location"]["uri"].endswith("shapes.k") for x in ws), ws)
    fr = c.request("textDocument/foldingRange", {"textDocument": {"uri": c.uri(M)}})
    ml = pos(src, "fn main")[0]
    check(label + "folding: function body and import list", any(x["startLine"] == ml for x in fr) and any(x["startLine"] == 1 for x in fr), fr)
    sr = c.request("textDocument/selectionRange", {"textDocument": {"uri": c.uri(M)}, "positions": [dict(zip(("line", "character"), pos(src, "norm1", 2)))]})
    depth, node = 0, sr[0]
    while node:
        depth, node = depth + 1, node.get("parent")
    check(label + "selection ranges nest outward", depth >= 4 and sr[0]["range"]["start"]["character"] == pos(src, "norm1")[1], (depth, sr[0]["range"]))
    sh = c.request("textDocument/signatureHelp", c.at(M, *pos(src, "describe(n)", 9)))
    check(label + "signature help: every overload", sh and {x["label"] for x in sh["signatures"]} == {"fn describe(v: i32) -> string", "fn describe(const p: Point) -> string"}, sh)
    check(label + "signature help: parameter offsets", sh and sh["signatures"][0]["parameters"] and sh["activeParameter"] == 0, sh)

    # --- hints, hierarchies, lenses
    labels = [(x["position"]["line"], x["label"]) for x in ih]
    check(label + "inlay: parameter names at calls", (pos(src, "clamp(c")[0], "v:") in labels and (pos(src, "tier(n)")[0], "x:") in labels, labels)
    check(label + "inlay: not when the argument says it already", (pos(src, "tier(n)")[0], "n:") not in labels, labels)
    check(label + "tokens: requires-constrained call is marked", "overloaded" in tok("wide(7")[2], tok("wide(7"))
    S2 = "src/shapes.k"
    c.open(S2, SHAPES)
    sih = c.request("textDocument/inlayHint", {"textDocument": {"uri": c.uri(S2)}, "range": {}})
    comp = [x["label"] for x in sih if x["position"]["line"] == pos(SHAPES, "interface Math")[0]]
    check(label + "inlay: a composed interface shows what it inherits", comp and "op -" in comp[0] and "op +" in comp[0], sih)
    ti = c.request("textDocument/prepareTypeHierarchy", c.at(S2, *pos(SHAPES, "class Derived", 6)))
    check(label + "type hierarchy: prepare", ti and ti[0]["name"] == "Derived", ti)
    if ti:
        sup = c.request("typeHierarchy/supertypes", {"item": ti[0]})
        check(label + "type hierarchy: supertypes", [x["name"] for x in sup] == ["Base"], sup)
        sub = c.request("typeHierarchy/subtypes", {"item": sup[0]}) if sup else None
        check(label + "type hierarchy: subtypes", sub and [x["name"] for x in sub] == ["Derived"], sub)
    im = c.request("textDocument/implementation", c.at(S2, *pos(SHAPES, "class Base", 6)))
    check(label + "implementation: the types that derive it", im and im[0]["range"]["start"]["line"] == pos(SHAPES, "class Derived")[0], im)
    ci = c.request("textDocument/prepareCallHierarchy", c.at(M, *pos(src, "clamp(c")))
    check(label + "call hierarchy: prepare", ci and ci[0]["name"] == "clamp", ci)
    if ci:
        inc = c.request("callHierarchy/incomingCalls", {"item": ci[0]})
        check(label + "call hierarchy: incoming", [x["from"]["name"] for x in inc] == ["main"], inc)
        out_ = c.request("callHierarchy/outgoingCalls", {"item": inc[0]["from"]}) if inc else []
        check(label + "call hierarchy: outgoing", {"clamp", "describe", "tier", "norm1"} <= {x["to"]["name"] for x in out_}, out_)
    cl = c.request("textDocument/codeLens", {"textDocument": {"uri": c.uri(M)}})
    titles = {x["range"]["start"]["line"]: x["command"]["title"] for x in cl}
    check(label + "code lens: reference counts", titles.get(pos(src, "fn clamp")[0]) == "1 reference", titles)
    rt = c.request("textDocument/semanticTokens/range", {"textDocument": {"uri": c.uri(M)}, "range": {"start": {"line": pos(src, "fn main")[0], "character": 0}, "end": {"line": pos(src, "fn main")[0] + 2, "character": 0}}})
    rtd = decode(rt["data"], src)
    check(label + "semantic tokens: range", rtd and all(pos(src, "fn main")[0] <= x[0] <= pos(src, "fn main")[0] + 2 for x in rtd) and any(x[2] == "main" for x in rtd), rtd[:4])
    rn2 = c.request("textDocument/rename", dict(c.at(S2, *pos(SHAPES, "class Crate", 6)), newName="Bin"))
    lines_hit = sorted(e["range"]["start"]["line"] for v in (rn2 or {}).get("changes", {}).values() for e in v)
    want = sorted([pos(SHAPES, "class Crate")[0], pos(SHAPES, "fn Crate(self) =")[0], pos(SHAPES, "fn Crate(self, v")[0]])
    check(label + "rename: a class renames its constructors", lines_hit == want, (lines_hit, want))
    rn3 = c.request("textDocument/rename", dict(c.at(S2, *pos(SHAPES, "fn Crate(self, v", 3)), newName="Bin"))
    check(label + "rename: from a constructor renames the class", sorted(e["range"]["start"]["line"] for v in (rn3 or {}).get("changes", {}).values() for e in v) == want, rn3)
    hv = c.request("textDocument/hover", c.at(S2, *pos(SHAPES, "interface Math", 10)))["contents"]["value"]
    check(label + "hover: an interface shows every requirement, Self as written", "fn op +(self, Self) -> Self" in hv and "fn op -(self, Self) -> Self" in hv and "inherited" in hv, hv)
    hv = c.request("textDocument/hover", c.at(S2, *pos(SHAPES, "class Base", 6)))["contents"]["value"]
    check(label + "hover: a class lists fields, methods and extension methods", "var id: i32" in hv and "fn label(const self) -> i32" in hv and "fn doubled(const self) -> i32  // extend" in hv, hv)
    check(label + "hover: size and alignment of a plain class", "size 4 bytes, align 4" in hv, hv)
    hv = c.request("textDocument/hover", c.at(S2, *pos(SHAPES, "struct Pair", 7)))["contents"]["value"]
    check(label + "hover: struct layout with padding", "size 16 bytes, align 8" in hv, hv)
    hv = c.request("textDocument/hover", c.at(S2, *pos(SHAPES, "enum Level", 5)))["contents"]["value"]
    check(label + "hover: a plain enum shows its underlying type, every variant with its value, and its layout",
          "enum Level derives u32" in hv and "Low = 1" in hv and "Mid = 2" in hv and "High = 10" in hv and "size 4 bytes, align 4" in hv, hv)
    hv = c.request("textDocument/hover", c.at(S2, *pos(SHAPES, "enum Color", 5)))["contents"]["value"]
    check(label + "hover: a derives u8 enum is one byte", "enum Color derives u8" in hv and "Blue = 2" in hv and "size 1 bytes, align 1" in hv, hv)
    hv = c.request("textDocument/hover", c.at(S2, *pos(SHAPES, "enum Shape", 5)))["contents"]["value"]
    check(label + "hover: an ADT enum lists each variant with its payload",
          "Circle { r: f64 }" in hv and "Rect { w: f64, h: f64 }" in hv and "Empty" in hv, hv)
    hv = c.request("textDocument/hover", c.at(S2, *pos(SHAPES, "union Bits", 6)))["contents"]["value"]
    check(label + "hover: a union lists its members and its layout",
          "var as_u32: u32" in hv and "var as_f32: f32" in hv and "size 4 bytes, align 4" in hv, hv)
    hv = c.request("textDocument/hover", c.at(S2, *pos(SHAPES, "Mid,")))["contents"]["value"]
    check(label + "hover: a variant shows its enum and value", "(variant) Level::Mid = 2" in hv, hv)
    hv = c.request("textDocument/hover", c.at(S2, *pos(SHAPES, "Rect {")))["contents"]["value"]
    check(label + "hover: an ADT variant shows its payload", "(variant) Shape::Rect { w: f64, h: f64 }" in hv, hv)
    st = {(x[2], frozenset(x[4])) for x in tokens(c, S2, SHAPES) if x[0] == pos(SHAPES, "b.doubled()")[0]}
    check(label + "tokens: an extension method call is marked", any(w == "doubled" and "extension" in m for w, m in st), st)
    im = c.request("textDocument/implementation", c.at(S2, *pos(SHAPES, "fn label", 3)))
    check(label + "implementation: a single method", im and [x["range"]["start"]["line"] for x in im] == [pos(SHAPES, "fn label", 0, 1)[0]], im)
    c.notify("textDocument/didClose", {"textDocument": {"uri": c.uri(S2)}})

    # --- token deltas: the same tokens again is an empty edit list
    full = c.request("textDocument/semanticTokens/full", {"textDocument": {"uri": c.uri(M)}})
    check(label + "semantic tokens: a result id", "resultId" in full, full.keys())
    dl = c.request("textDocument/semanticTokens/full/delta", {"textDocument": {"uri": c.uri(M)}, "previousResultId": full.get("resultId", "")})
    check(label + "semantic tokens: delta of no change is empty", dl.get("edits") == [], dl)
    grown = src.replace("    var t = tier(n)", "    var t = tier(n)\n    var t2 = tier(t)")
    c.change(M, 50, grown)
    dl2 = c.request("textDocument/semanticTokens/full/delta", {"textDocument": {"uri": c.uri(M)}, "previousResultId": dl.get("resultId", "")})
    ed = dl2.get("edits") or []
    applied = list(full["data"])
    for e in ed:
        applied[e["start"]:e["start"] + e["deleteCount"]] = e.get("data", [])
    again = c.request("textDocument/semanticTokens/full", {"textDocument": {"uri": c.uri(M)}})
    check(label + "semantic tokens: applying the delta gives the full result", len(ed) == 1 and applied == again["data"] and len(ed[0]["data"]) < len(again["data"]), (len(ed), len(applied), len(again["data"])))
    c.change(M, 51, src)
    tokens(c, M, src)

    # --- signature help for a function no file has used yet, from its text
    unused = src.replace("    var t = tier(n)", "    var t = tier(n)\n    unused_so_far(")
    c.change(M, 52, unused)
    sh2 = c.request("textDocument/signatureHelp", c.at(M, pos(unused, "unused_so_far(")[0], pos(unused, "unused_so_far(")[1] + 14))
    check(label + "signature help: a function nothing uses yet", sh2 and sh2["signatures"][0]["label"] == "fn unused_so_far(first: i32, second: string) -> i32" and len(sh2["signatures"][0]["parameters"]) == 2, sh2)
    c.change(M, 53, src)

    # --- on-type formatting: a `}` goes to its opener's column
    ot = src.replace("    return v\n}", "    return v\n        }")
    c.change(M, 54, ot)
    ol, oc = pos(ot, "        }")
    fe = c.request("textDocument/onTypeFormatting", {"textDocument": {"uri": c.uri(M)}, "position": {"line": ol, "character": oc + 9}, "ch": "}", "options": {"tabSize": 4, "insertSpaces": True}})
    check(label + "on-type formatting: closing brace", fe and fe[0]["newText"] == "" and fe[0]["range"]["end"]["character"] == 8, fe)
    c.change(M, 55, src)
    tokens(c, M, src)

    # --- diagnostics from the unsaved buffer, and the fix-it as a code action
    edited = src.replace("var n = clamp(c.norm1())", "var n = clamp(c.norm1() as i32)")
    c.change(M, 2, edited)
    c.settle()
    ds = c.diagnostics(M) or []
    check(label + "diagnostics: from the unsaved buffer", [x["code"] for x in ds] == ["SC031W"], ds)
    if ds:
        acts = c.request("textDocument/codeAction", {"textDocument": {"uri": c.uri(M)}, "range": ds[0]["range"], "context": {"diagnostics": ds}})
        ed = acts and list(acts[0]["edit"]["changes"].values())[0][0]
        check(label + "code action: fix-it edit", bool(acts) and acts[0]["title"] == "remove the cast" and ed["newText"] == "", acts)

    # --- an unsaved edit in an IMPORTED file reaches its importer
    S = "src/shapes.k"
    c.change(M, 3, src)
    c.open(S, SHAPES.replace("pub fn norm1(const self) -> i32", "pub fn norm9(const self) -> i32"))
    c.settle()
    ds = c.diagnostics(M) or []
    check(label + "overlay: importer sees the imported buffer", any(x["code"] == "R025E" for x in ds), ds)
    c.change(S, 2, SHAPES)
    c.settle()
    check(label + "overlay: and recovers", not c.diagnostics(M), c.diagnostics(M))

    # --- a buffer that stops parsing keeps its last good index
    broken = src.replace("var t = tier(n)", "var t = tier(n")
    c.change(M, 4, broken)
    c.settle()
    r = c.request("textDocument/semanticTokens/full", {"textDocument": {"uri": c.uri(M)}}, raw=True)
    lx = decode(r["data"], broken) if isinstance(r, dict) and "data" in r else []
    check(label + "syntax error: tokens are the current text's lexical ones (keywords at their places, no names)",
          lx and all(w in KEYWORDS for _, _, w, ty, _ in lx if ty == "keyword") and {"fn", "var", "return"} <= {w for _, _, w, _, _ in lx}
          and not any(ty in ("function", "variable", "method", "class") for _, _, _, ty, _ in lx), r)
    check(label + "syntax error: reported", any(x["severity"] == 1 for x in c.diagnostics(M) or []), c.diagnostics(M))
    ih2 = c.request("textDocument/inlayHint", {"textDocument": {"uri": c.uri(M)}, "range": {}}, raw=True)
    check(label + "syntax error: stale inlay hints are not sent", isinstance(ih2, dict) and "__error__" in ih2, ih2)
    h = c.request("textDocument/hover", c.at(M, *pos(src, "describe(n)")))
    check(label + "syntax error: hover gives nothing rather than a stale answer", h is None, h)
    c.change(M, 5, src)
    t = tokens(c, M, src)
    check(label + "syntax error: tokens return once it parses again", len(t) > 20, len(t))

    # --- completion
    l, _ = pos(src, "return 0", 0, 0)
    lines = src.split("\n")
    def complete(text_line, ch, version):
        c.change(M, version, "\n".join(lines[:l] + [text_line] + lines[l:]))
        return c.request("textDocument/completion", c.at(M, l, ch))["items"]
    it = complete("    c.", 6, 6)
    check(label + "completion: members", {i["label"] for i in it} == {"x", "y", "norm1"}, it)
    it = complete("    c.no", 8, 7)
    check(label + "completion: members with a prefix typed", "norm1" in {i["label"] for i in it}, it)
    it = complete("    io::", 8, 8)
    check(label + "completion: module contents", "println" in {i["label"] for i in it} and "write_line_" not in {i["label"] for i in it}, it)
    it = complete("    Color::", 11, 9)
    check(label + "completion: enum variants", {"Red", "Green", "Blue"} <= {i["label"] for i in it}, it)
    it = complete("    cl", 6, 10)
    names = [i["label"] for i in it]
    check(label + "completion: scope", all(n in names for n in ("clamp", "c", "col", "LIMIT", "Point", "describe", "return")), names[:40])
    check(label + "completion: locals first", names.index("col") < names.index("Point"), names[:20])
    check(label + "completion: items say what they replace", all("textEdit" in i for i in it), it[:2])
    it = complete("    desc", 8, 60)
    d1 = next((i for i in it if i["label"] == "describe"), None)
    check(label + "completion: documentation is not in the list", d1 is not None and "documentation" not in d1, d1)
    if d1:
        rs = c.request("completionItem/resolve", d1)
        check(label + "completion: resolve adds the documentation", rs and "Describes" in rs.get("documentation", {}).get("value", "") and rs["label"] == "describe", rs)

    # inside an f-string's interpolation: completion, and code colours
    it = complete('    io::println(f"p {c.} and {n + 1} {describe(n)}")', 23, 11)
    check(label + "completion: inside an f-string", {i["label"] for i in it} == {"x", "y", "norm1"}, it)
    fs = "\n".join(lines[:l] + ['    io::println(f"p {c.norm1()} and {n + 1} {describe(n)}")'] + lines[l:])
    c.change(M, 12, fs)
    ft = [x for x in tokens(c, M, fs) if x[0] == l]
    kinds = {(w, ty) for _, _, w, ty, _ in ft}
    check(label + "f-string: names inside are code", ("c", "variable") in kinds and ("norm1", "method") in kinds and ("describe", "function") in kinds, ft)
    check(label + "f-string: numbers and operators", ("1", "number") in kinds and ("+", "operator") in kinds, ft)
    check(label + "f-string: the text is still a string", any(ty == "string" and "and" in w for w, ty in kinds), ft)
    check(label + "f-string: overload mark survives", any(w == "describe" and "overloaded" in m for _, _, w, _, m in ft), ft)

    # imports: path segments from the search roots, then a file's names
    def imp(text_line, ch, version):
        c.change(M, version, text_line + "\n" + src)
        return [i["label"] for i in c.request("textDocument/completion", c.at(M, 0, ch))["items"]]
    names = imp("import ", 7, 13)
    check(label + "import completion: roots", "shapes" in names and "std" in names, names)
    names = imp("import std::", 12, 14)
    check(label + "import completion: a library's modules", "io" in names and "module" not in names, names)
    names = imp("import shapes::", 15, 15)
    check(label + "import completion: a file's declarations", {"Point", "describe", "tier", "Color"} <= set(names), names)
    names = imp("import shapes::{Point, ", 23, 16)
    check(label + "import completion: inside braces", "describe" in names and "std" not in names, names)
    c.change(M, 17, src)

    # --- formatting is kfmt's
    f = c.request("textDocument/formatting", {"textDocument": {"uri": c.uri(M)}, "options": {"tabSize": 4, "insertSpaces": True}})
    check(label + "formatting: a minimal edit, not the whole file", isinstance(f, list) and (not f or len(f[0]["newText"]) < len(src)), f)
    rf = c.request("textDocument/rangeFormatting", {"textDocument": {"uri": c.uri(M)}, "range": {"start": {"line": 0, "character": 0}, "end": {"line": 2, "character": 0}}, "options": {"tabSize": 4, "insertSpaces": True}})
    check(label + "range formatting: nothing outside the range", rf == [] or all(e["range"]["end"]["line"] <= 3 for e in rf), rf)

    # --- cancellation: a parked request is answered "cancelled"
    # A file nothing has analysed yet: its first request always waits, so
    # the cancel reaches a request that is still parked.
    open(os.path.join(root, "src", "scratch.k"), "w").write("fn lonely() -> i32 { return 1 }\n")
    c.open("src/scratch.k")
    c.id += 1
    cid = c.id
    c.send({"jsonrpc": "2.0", "id": cid, "method": "textDocument/hover", "params": c.at("src/scratch.k", 0, 4)})
    c.notify("$/cancelRequest", {"id": cid})
    got = None
    end = time.time() + 20
    while time.time() < end and got is None:
        try:
            m = c.q.get(timeout=0.1)
        except Exception:
            continue
        if m and m.get("id") == cid:
            got = m
        elif m and "method" in m:
            c.notes.append(m)
    check(label + "cancellation: a waiting request is cancelled, not computed", got is not None and got.get("error", {}).get("code") == -32800, got)
    c.notify("textDocument/didClose", {"textDocument": {"uri": c.uri("src/scratch.k")}})
    os.remove(os.path.join(root, "src", "scratch.k"))
    c.change(M, 91, src)
    tokens(c, M, src)
    check(label + "log: the client is told what the server is doing", any(n["method"] == "window/logMessage" and "kals started" in n["params"]["message"] for n in c.notes), [n["method"] for n in c.notes][:6])

    check(label + "clean shutdown", c.stop() == 0, c.stderr[-5:])


def crash(exe, root):
    """A worker that dies must cost one stale answer, not the server."""
    c = Client(exe, root, env={"KAIRO_DEBUG_FORCE_ICE": "1"})
    c.start()
    M = "src/main.k"
    src = c.open(M)
    good = tokens(c, M, src)
    bad = src.replace("var col = Color::Green", 'var col: i32 = "no"')   # an error makes the hook fire
    c.change(M, 2, bad)
    r = c.request("textDocument/semanticTokens/full", {"textDocument": {"uri": c.uri(M)}}, raw=True, timeout=90)
    check("crash: the server stays up and does not send stale tokens", len(good) > 20 and isinstance(r, dict) and r.get("__error__", {}).get("code") == -32801, (len(good), str(r)[:200]))
    # A crashing compiler symbolizes its own stack before it exits, which
    # takes seconds; the request above was answered (stale) before that.
    end = time.time() + 60
    while time.time() < end and not any(n["method"] == "window/logMessage" for n in c.notes):
        c.pump(0.2)
    check("crash: it is reported", any(n["method"] == "window/logMessage" for n in c.notes), [n["method"] for n in c.notes])
    c.change(M, 3, src)
    c.settle()
    h = c.request("textDocument/hover", c.at(M, *pos(src, "describe(n)")))
    check("crash: and recovers on the next good run", h and "fn describe" in h["contents"]["value"], h)
    check("crash: clean shutdown", c.stop() == 0)


def fnv1a(text):
    h = 14695981039346656037
    for b in text.encode():
        h = ((h ^ b) * 1099511628211) & 0xFFFFFFFFFFFFFFFF
    return str(h)


def lsp_index(text, line, ch):
    """(line, UTF-16 character) -> index into the str, clamped as the server
    clamps: to the line's content, a CR before the LF excluded."""
    lines = text.split("\n")
    if line >= len(lines):
        return len(text)
    start = sum(len(l) + 1 for l in lines[:line])
    content = lines[line][:-1] if lines[line].endswith("\r") and line + 1 < len(lines) else lines[line]
    units, i = 0, 0
    while i < len(content) and units < ch:
        units += 2 if ord(content[i]) > 0xFFFF else 1
        i += 1
    return start + i


def lsp_pos(text, index):
    """index into the str -> (line, UTF-16 character)."""
    before = text[:index]
    line = before.count("\n")
    col = before[before.rfind("\n") + 1:]
    return line, sum(2 if ord(ch) > 0xFFFF else 1 for ch in col)


def edits(exe, root):
    """Incremental didChange: the server's text must equal a reference copy
    after every kind of edit, compared by hash through `$/kals/text`."""
    import random
    c = Client(exe, root)
    c.start()
    E = "src/edit.k"
    text = "fn f() -> i32 {\n    return 1\n}\n"
    open(os.path.join(root, E), "w").write(text)
    c.open(E, text)
    ver = [1]

    def apply(changes):
        nonlocal text
        cc = []
        for (sl, sc, el, ec, new) in changes:
            a, b = lsp_index(text, sl, sc), lsp_index(text, el, ec)
            text = text[:a] + new + text[b:]
            cc.append({"range": {"start": {"line": sl, "character": sc}, "end": {"line": el, "character": ec}}, "text": new})
        ver[0] += 1
        c.notify("textDocument/didChange", {"textDocument": {"uri": c.uri(E), "version": ver[0]}, "contentChanges": cc})

    def same(name):
        r = c.request("$/kals/text", {"textDocument": {"uri": c.uri(E)}})
        check("edits: " + name, r and r["hash"] == fnv1a(text) and r["size"] == len(text.encode()) and r["lines"] == text.count("\n") + 1, (r, len(text.encode()), text[:80]))

    apply([(1, 4, 1, 4, "var x = 2\n    ")]); same("insert")
    apply([(1, 4, 2, 4, "")]); same("delete")
    apply([(0, 3, 2, 1, "g() -> i32 {\n    a\n    b\n}")]); same("multi-line replace")
    apply([(0, 0, 0, 0, "// head\n")]); same("edit at the start")
    n = text.count("\n")
    apply([(n, 0, n, 0, "// tail")]); same("edit at the end")
    apply([(0, 0, 0, 0, "// crlf\r\nfn h() {\r\n}\r\n")]); same("CRLF lines")
    apply([(1, 6, 1, 6, "é中😀")]); same("non-ASCII inserted")
    l, ch = lsp_pos(text, text.index("😀") + 1)
    apply([(l, ch, l, ch, "Z")]); same("a UTF-16 column after a surrogate pair")
    alphabet = ["a", "b", " ", "\n", "é", "中", "😀", "\r\n", "{", "}", "xyz"]
    rnd = random.Random(1234)
    for k in range(1000):
        a = rnd.randrange(0, len(text) + 1)
        b = min(len(text), a + rnd.choice([0, 0, 1, 2, 5, 20]))
        # never split a CRLF: the server's line table keeps the CR with its line
        if 0 < a < len(text) and text[a - 1] == "\r" and text[a] == "\n":
            a -= 1
        if 0 < b < len(text) and text[b - 1] == "\r" and text[b] == "\n":
            b += 1
        new = "".join(rnd.choice(alphabet) for _ in range(rnd.randrange(0, 4)))
        sl, sc = lsp_pos(text, a)
        el, ec = lsp_pos(text, b)
        apply([(sl, sc, el, ec, new)])
        if k % 250 == 249:
            same(f"random edits ({k + 1})")
    # Past the initial gap (4 KB of bytes, 256 line slots): both grow, and
    # edits far apart move the gaps a long way.
    big = "".join(f"line {i} é中😀\r\n" if i % 3 == 0 else f"    var v{i} = {i}\n" for i in range(600))
    l, ch = lsp_pos(text, len(text) // 2)
    apply([(l, ch, l, ch, big)]); same("a 13 KB, 600-line insert grows both gaps")
    for k in range(300):
        a = rnd.randrange(0, len(text) + 1)
        b = min(len(text), a + rnd.choice([0, 1, 30, 400]))
        if 0 < a < len(text) and text[a - 1] == "\r" and text[a] == "\n":
            a -= 1
        if 0 < b < len(text) and text[b - 1] == "\r" and text[b] == "\n":
            b += 1
        new = rnd.choice(["", "x", "\n", big[:rnd.randrange(0, 3000)]])
        sl, sc = lsp_pos(text, a)
        el, ec = lsp_pos(text, b)
        apply([(sl, sc, el, ec, new)])
    same("300 edits far apart on a large buffer")
    n = text.count("\n")
    apply([(0, 0, n, 0, "")]); same("deleting nearly all of it")
    # several changes in one notification, applied in order
    apply([(0, 0, 0, 0, "A\n"), (0, 1, 0, 1, "B"), (1, 0, 1, 0, "C")]); same("several changes in one message")
    fr = c.request("textDocument/foldingRange", {"textDocument": {"uri": c.uri(E)}})
    check("edits: a text request reads the edited text", isinstance(fr, list), fr)
    c.notify("textDocument/didClose", {"textDocument": {"uri": c.uri(E)}})
    os.remove(os.path.join(root, E))
    check("edits: clean shutdown", c.stop() == 0)


MLIB = """pub macro seven!() { 7 }
pub macro hello!() { "hi" }
"""

MACROS = """import self::mlib

macro double!(x) {
    x + x
}

macro twice!(s) {
    var a1 = s
    var a2 = s
}

macro quad!(y) {
    double!(y) * 2
}

fn main() -> i32 {
    var a = double!(5)
    twice!(a)
    var s = mlib::hello!()
    var q = quad!(mlib::seven!())
    return a
}
"""


def macros(exe, root):
    c = Client(exe, root)
    c.start()
    X = "src/macros.k"
    open(os.path.join(root, "src", "mlib.k"), "w").write(MLIB)
    open(os.path.join(root, X), "w").write(MACROS)
    c.open(X, MACROS)
    h = c.request("textDocument/hover", c.at(X, *pos(MACROS, "double!(5)", 2)))
    v = (h or {}).get("contents", {}).get("value", "")
    check("macro: hover shows the expansion", "Expands to" in v and "```kairo\n5 + 5\n```" in v, h)
    h2 = c.request("textDocument/hover", c.at(X, *pos(MACROS, "twice!(a)", 1)))
    v2 = (h2 or {}).get("contents", {}).get("value", "")
    check("macro: a multi-line expansion keeps its lines", "var a1 = a\nvar a2 = a" in v2, h2)
    h3 = c.request("textDocument/hover", c.at(X, *pos(MACROS, "mlib::hello!()", 8)))
    check("macro: an imported macro's string literal", '```kairo\n"hi"\n```' in ((h3 or {}).get("contents", {}).get("value", "")), h3)
    h4 = c.request("textDocument/hover", c.at(X, *pos(MACROS, "quad!(mlib", 1)))
    check("macro: a nested invocation shows the whole expansion, imported literal included",
          "```kairo\n7 + 7 * 2\n```" in ((h4 or {}).get("contents", {}).get("value", "")), h4)
    l, ch = pos(MACROS, "double!(5)")
    rng = {"start": {"line": l, "character": ch + 1}, "end": {"line": l, "character": ch + 1}}
    acts = c.request("textDocument/codeAction", {"textDocument": {"uri": c.uri(X)}, "range": rng, "context": {"diagnostics": []}}) or []
    view = next((a for a in acts if a["title"] == "View expanded macro"), None)
    here = next((a for a in acts if a["title"] == "Expand macro here"), None)
    check("macro: 'View expanded macro' runs kairo.showMacroExpansion with [uri, range, text]",
          view and view["command"]["command"] == "kairo.showMacroExpansion" and view["command"]["arguments"][0] == c.uri(X)
          and view["command"]["arguments"][1]["start"] == {"line": l, "character": ch}
          and view["command"]["arguments"][1]["end"] == {"line": l, "character": ch + len("double!(5)")}
          and view["command"]["arguments"][2] == "5 + 5", acts)
    check("macro: 'Expand macro here' is an edit", here and list(here["edit"]["changes"].values())[0][0]["newText"] == "5 + 5", acts)
    if here:
        e = list(here["edit"]["changes"].values())[0][0]
        a, b = lsp_index(MACROS, e["range"]["start"]["line"], e["range"]["start"]["character"]), lsp_index(MACROS, e["range"]["end"]["line"], e["range"]["end"]["character"])
        expanded = MACROS[:a] + e["newText"] + MACROS[b:]
        c.change(X, 2, expanded)
        c.settle()
        d = c.diagnostics(X)
        check("macro: the expanded text parses and checks", "var a = 5 + 5" in expanded and not [x for x in d or [] if x["severity"] == 1], d)
    c.notify("textDocument/didClose", {"textDocument": {"uri": c.uri(X)}})
    os.remove(os.path.join(root, X))
    os.remove(os.path.join(root, "src", "mlib.k"))
    check("macro: clean shutdown", c.stop() == 0)


def waiting(exe, root):
    """A request on a file whose own entry cannot start yet (another entry's
    first run holds the slot, so can_start refuses it) waits for that entry's
    first index. The loop must not spin on the refused entry's passed
    deadline: when it did, its turns were 1 ms and a wait counted in turns
    gave up after about 3 s instead of two minutes."""
    c = Client(exe, root, env={"KALS_DEBUG_INDEX_DELAY_MS": "2500"})
    c.start()
    c.open("src/main.k")
    W = "alone.k"   # under no root of the project's entry: its own entry at once
    text = "/// Alone.\nfn alone() -> i32 { return 1 }\n"
    open(os.path.join(root, W), "w").write(text)
    c.open(W, text)
    t = time.time()
    h = c.request("textDocument/hover", c.at(W, 1, 4), timeout=60)
    check("waiting: a request parked behind another entry's run gets its answer", h and "fn alone" in h["contents"]["value"], (h, time.time() - t))
    c.notify("textDocument/didClose", {"textDocument": {"uri": c.uri(W)}})
    os.remove(os.path.join(root, W))
    check("waiting: clean shutdown", c.stop() == 0)


def reruns(exe, root):
    """What starts a run of an entry, and what does not (P856). A run is a
    whole compile of the entry's graph, so: saving a buffer, or opening or
    closing one whose text is what the last run read from the disk, starts
    none; and a change made during a slow run kills it, so the new text is
    analysed once, not after the stale run has been waited out."""
    c = Client(exe, root, env={"KALS_DEBUG_INDEX_DELAY_MS": "2500"})
    c.start()
    text = c.open("src/main.k")
    c.settle()

    def runs():
        return sum(1 for n in c.notes if n["method"] == "$/kals/analysed")

    n = runs()
    c.notify("textDocument/didSave", {"textDocument": {"uri": c.uri("src/main.k")}})
    c.pump(4)
    check("reruns: saving a buffer starts no run", runs() == n, runs() - n)
    c.open("src/shapes.k")
    c.pump(4)
    check("reruns: opening a file as it is on disk starts no run", runs() == n, runs() - n)
    h = c.request("textDocument/hover", c.at("src/shapes.k", *pos(SHAPES, "Shape")), timeout=20)
    check("reruns: and the file opened that way is answered for", bool(h), h)
    c.notify("textDocument/didClose", {"textDocument": {"uri": c.uri("src/shapes.k")}})
    c.pump(4)
    check("reruns: closing an unedited buffer starts no run", runs() == n, runs() - n)

    c.change("src/main.k", 2, text + "\n// one\n")
    c.pump(1.2)   # past the debounce: the run of "one" is in its delay
    c.change("src/main.k", 3, text + "\n// one two\n")
    ok = c.settle()
    c.pump(1)
    check("reruns: a change during a slow run replaces it (one result, not two)", ok and runs() == n + 1, runs() - n)
    c.change("src/main.k", 4, text)
    c.settle()
    check("reruns: clean shutdown", c.stop() == 0)


FIXIT = '''class Box {
    pub var v: i32
    pub fn Box(self) = default
    @copy
    pub fn Box(self, other: Self) {
        self.v = other.v
    }
    pub fn Box(self, v: i32) {
        self.v = v
    }

    pub fn op + (self, other: Self) -> Self {
        return Box(self.v + other.v)
    }
}

fn main() -> i32 {
    var b = Box(1) + Box(2)
    return b.v
}
'''


def fixits(exe, root):
    """An insertion fix-it inserts (P860): its edit is zero-width, where the
    diagnostic's own range is widened to be drawn. Widened, "make 'other'
    const" replaced the `o`: `const ther`."""
    F = "fixit.k"
    open(os.path.join(root, F), "w").write(FIXIT)
    c = Client(exe, root)
    c.start()
    c.open(F, FIXIT)
    c.settle()
    ds = [d for d in c.diagnostics(F) or [] if d.get("code") == "SC224W"]
    check("fixits: the never-mutated parameter is reported", len(ds) >= 1, c.diagnostics(F))
    out = None
    if ds:
        acts = c.request("textDocument/codeAction", {"textDocument": {"uri": c.uri(F)}, "range": ds[-1]["range"], "context": {"diagnostics": ds[-1:]}})
        for a in acts or []:
            for es in (a.get("edit", {}).get("changes", {}) or {}).values():
                for e in es:
                    if e["newText"].startswith("const"):
                        out = apply_edits(FIXIT, [e])
    check("fixits: applying an insertion keeps the character after it", out is not None and "const other: Self) -> Self" in out and "ther: Self) -> Self" in out and "const ther" not in out, out)
    c.notify("textDocument/didClose", {"textDocument": {"uri": c.uri(F)}})
    os.remove(os.path.join(root, F))
    check("fixits: clean shutdown", c.stop() == 0)


def syntax(exe, root):
    """The syntax-only pass: errors before the run, never overwritten by an
    older run, replaced by the run's when the text parses again. Every run
    is held back 1.5 s (KALS_DEBUG_INDEX_DELAY_MS) so the order is certain.
    Also: progress for the first analysis when the client takes it."""
    c = Client(exe, root, env={"KALS_DEBUG_INDEX_DELAY_MS": "1500"})
    c.start({"syntaxDebounceMs": 50, "debounceMs": 100}, progress=True)
    M = "src/main.k"
    src = c.open(M)
    c.settle()
    begins = [n for n in c.notes if n["method"] == "$/progress" and n["params"]["value"]["kind"] == "begin"]
    ends = [n for n in c.notes if n["method"] == "$/progress" and n["params"]["value"]["kind"] == "end"]
    created = [n for n in c.notes if n["method"] == "window/workDoneProgress/create"]
    check("progress: the first analysis shows begin and end", begins and ends and created
          and begins[0]["params"]["value"]["title"] == "Indexing Kairo"
          and begins[0]["params"]["token"] == ends[0]["params"]["token"] == created[0]["params"]["token"], [n["method"] for n in c.notes][:12])

    def syntax_errors():
        return [x for x in c.diagnostics(M) or [] if x["code"].startswith("S") and not x["code"].startswith("SC")]

    # A valid edit starts a run (held 1.5 s); a broken one lands meanwhile.
    valid = src.replace("var t = tier(n)", "var t = tier(n + 1)")
    c.change(M, 2, valid)
    c.pump(0.5)
    broken = valid.replace("var t = tier(n + 1)", "var t = tier(n + 1")
    mark = len(c.notes)
    c.change(M, 3, broken)
    end = time.time() + 20
    early = None
    while time.time() < end and early is None:
        for n in c.notes[mark:]:
            if n["method"] == "$/kals/analysed":
                early = False
                break
            if n["method"] == "textDocument/publishDiagnostics" and n["params"]["uri"] == c.uri(M) and any(x["code"].startswith("S") for x in n["params"]["diagnostics"]):
                early = True
                break
        c.pump(0.05)
    check("syntax pass: errors for an unparseable buffer arrive before the run", early is True, [n["method"] for n in c.notes[mark:]])
    # The run of the valid text (older) is slow, so the broken edit killed it
    # (reruns, P856); a fast one would land here. Either way the next result
    # must not overwrite the syntax errors.
    end = time.time() + 30
    landed = None
    while time.time() < end and landed is None:
        for n in c.notes[mark:]:
            if n["method"] == "$/kals/analysed":
                landed = n
        c.pump(0.05)
    check("syntax pass: an older run does not overwrite the newer syntax errors", landed is not None and syntax_errors(), (landed, c.diagnostics(M)))
    r = c.request("textDocument/semanticTokens/full", {"textDocument": {"uri": c.uri(M)}}, raw=True)
    lx = decode(r["data"], broken) if isinstance(r, dict) and "data" in r else []
    check("syntax pass: lexical tokens while it does not parse", lx and {"fn", "var", "return"} <= {w for _, _, w, _, _ in lx}, r)
    # It parses again, with a semantic warning: the run's diagnostics replace the syntax ones.
    fixed = src.replace("var n = clamp(c.norm1())", "var n = clamp(c.norm1() as i32)")
    c.change(M, 4, fixed)
    c.settle()
    ds = c.diagnostics(M) or []
    check("syntax pass: replaced by the run's diagnostics once it parses", [x["code"] for x in ds] == ["SC031W"], ds)
    check("syntax pass: clean shutdown", c.stop() == 0)


IFACE = """import std::io

/// A counter.
pub class Counter {
    pub var n: i32 = 0

    pub fn Counter(self) = default

    pub fn op finally(self) { }

    /// Adds one.
    pub fn bump(self) {
        self.n += 1
    }

    pub fn <T> add(self, v: T) -> i32 requires sizeof(T) > 4 {
        return 1
    }

    pub fn get(const self) -> i32 {
        return self.n
    }

    pub fn risky(self, x: i32) panic -> i32 {
        return x
    }

    pub static fn zero() -> i32 {
        return 0
    }

    fn hidden(self) -> i32 {
        return 0
    }
}

extend Counter {
    pub fn twice(const self) -> i32 {
        return self.n * 2
    }
}

pub interface IOther {
    fn ping(const self) -> i32
}

pub class Other {
    pub fn ping(const self) -> i32 { return 1 }
}
"""


def apply_edits(text, edits):
    spans = sorted(((lsp_index(text, e["range"]["start"]["line"], e["range"]["start"]["character"]),
                     lsp_index(text, e["range"]["end"]["line"], e["range"]["end"]["character"]), e["newText"]) for e in edits),
                   reverse=True)
    for a, b, new in spans:
        text = text[:a] + new + text[b:]
    return text


STYLES = """@deprecated("use fresh()")
fn stale() -> i32 { return 1 }

fn fresh() -> i32 { return 2 }

fn bump(@inout x: i32) { x = x + 1 }

fn poke(p: *i32) -> i32 { return *p }

fn risky(v: i32) panic -> i32 {
    if v < 0 {
        panic "negative"
    }
    return v
}

fn wrap() panic -> i32 { return risky(1) }

fn main() -> i32 {
    var n: i32 = 0
    const k: i32 = 2
    bump(&n)
    var a = poke(&n)
    var u: unsafe *i32 = unsafe &n
    return stale() + fresh() + n + k + a
}
"""


def styles(exe, root):
    """The style table's modifiers (section 5, P828): what the server sends."""
    X = "src/styles.k"
    open(os.path.join(root, X), "w").write(STYLES)
    for want in (True, False):
        c = Client(exe, root)
        c.start(options={"highlightPanics": want})
        c.open(X, STYLES)
        c.settle()
        by = {(l, col): (w, ty, m) for l, col, w, ty, m in tokens(c, X, STYLES)}
        tok = lambda needle, off=0, nth=0: by.get(pos(STYLES, needle, off, nth), ("", "", set()))
        if want:
            check("styles: deprecated use is struck through", "deprecated" in tok("stale() +")[2], tok("stale() +"))
            check("styles: a plain call is not deprecated", "deprecated" not in tok("fresh() +")[2], tok("fresh() +"))
            check("styles: @inout marker mutates", "mutates" in tok("&n)")[2], tok("&n)"))
            check("styles: address of a mutable to a pointer parameter mutates", "mutates" in tok("&n)", 0, 1)[2], tok("&n)", 0, 1))
            check("styles: var binding is mutable", "mutable" in tok("n: i32")[2], tok("n: i32"))
            check("styles: const binding is not mutable", "mutable" not in tok("k: i32")[2], tok("k: i32"))
            check("styles: the unsafe keyword is unsafe", "unsafe" in tok("unsafe &n")[2], tok("unsafe &n"))
            check("styles: the operator unsafe permits is unsafe", "unsafe" in tok("unsafe &n", 7)[2], tok("unsafe &n", 7))
            check("styles: a call to a panic function panics (asked for)", "panics" in tok("risky(1)")[2], tok("risky(1)"))
        else:
            check("styles: panics not sent unless asked", "panics" not in tok("risky(1)")[2], tok("risky(1)"))
        c.stop()


def interfaces(exe, root):
    """Generate interface for 'Name': the edit, applied, still type-checks."""
    c = Client(exe, root)
    c.start()
    X = "src/iface.k"
    open(os.path.join(root, X), "w").write(IFACE)
    c.open(X, IFACE)
    c.settle()
    l, ch = pos(IFACE, "class Counter", 7)
    rng = {"start": {"line": l, "character": ch}, "end": {"line": l, "character": ch}}
    acts = c.request("textDocument/codeAction", {"textDocument": {"uri": c.uri(X)}, "range": rng, "context": {"diagnostics": []}}) or []
    gen = next((a for a in acts if a["title"] == "Generate interface for 'Counter'"), None)
    check("interface: offered on a class name, as refactor.extract", gen and gen["kind"] == "refactor.extract", acts)
    l2, ch2 = pos(IFACE, "pub var n", 9)
    acts2 = c.request("textDocument/codeAction", {"textDocument": {"uri": c.uri(X)}, "range": {"start": {"line": l2, "character": ch2}, "end": {"line": l2, "character": ch2}}, "context": {"diagnostics": []}}) or []
    check("interface: not offered off a type name", not any(a["title"].startswith("Generate interface") for a in acts2), acts2)
    if gen:
        edits = list(gen["edit"]["changes"].values())[0]
        new = apply_edits(IFACE, edits)
        body = new[new.find("pub interface ICounter"):]
        body = body[:body.find("}") + 1]
        check("interface: public instance methods with their docs and exact signatures",
              "    /// Adds one.\n    fn bump(self)\n" in body and "fn <T> add(self, v: T) -> i32 requires sizeof(T) > 4" in body
              and "fn get(const self) -> i32" in body, body)
        check("interface: no constructor, destructor, static, private or extension method",
              all(w not in body for w in ("Counter(self)", "finally", "zero", "hidden", "twice")), body)
        check("interface: a bare-panic method is left out with a note", "// risky:" in body and "fn risky" not in body, body)
        check("interface: above the class and its doc, and the class gains impl",
              "}\n\n/// A counter.\npub class Counter impl ICounter {" in new, new[:400])
        c.change(X, 2, new)
        c.settle()
        ds = [x for x in (c.diagnostics(X) or []) if x.get("severity") == 1]
        check("interface: the edited file still type-checks", not ds, ds)
        l3, ch3 = pos(new, "class Other", 7)
        acts3 = c.request("textDocument/codeAction", {"textDocument": {"uri": c.uri(X)}, "range": {"start": {"line": l3, "character": ch3}, "end": {"line": l3, "character": ch3}}, "context": {"diagnostics": []}}) or []
        g3 = next((a for a in acts3 if a["title"].startswith("Generate interface")), None)
        txt = "".join(e["newText"] for e in list(g3["edit"]["changes"].values())[0]) if g3 else ""
        check("interface: IName taken, so NameInterface", "pub interface OtherInterface {" in txt and "impl OtherInterface" in txt, acts3)
    check("interface: clean shutdown", c.stop() == 0)


BR_A = """/// Adds.
pub fn add(a: i32, b: i32) -> i32 {
    return a + b
}

pub struct Point {
    pub var x: i32
    pub var y: i32
}
"""

BR_B = """#include "a.k"

int use() { return a::add(1, 2); }
"""


def bundled_clang(exe):
    c = os.path.join(os.path.dirname(exe), "clang++")
    return c if os.path.exists(c) else shutil.which("clang++")


def wait_for(pred, seconds, c=None):
    end = time.time() + seconds
    while time.time() < end:
        if pred():
            return True
        if c:
            c.pump(0.2)
        else:
            time.sleep(0.2)
    return pred()


def bridge(exe, base):
    """The clangd bridge (section 15): a.k, b.cc including it, and
    compile_commands.json; the header and the overlay, an edit through
    didChange, the bundled clang through the overlay, and clangd if present."""
    root = os.path.realpath(os.path.join(base, "bridge"))
    os.makedirs(root)
    open(os.path.join(root, "a.k"), "w").write(BR_A)
    open(os.path.join(root, "b.cc"), "w").write(BR_B)
    json.dump([{"directory": root, "file": "b.cc", "command": "clang++ -std=c++20 -c b.cc"}],
              open(os.path.join(root, "compile_commands.json"), "w"))
    cache = os.path.join(root, ".kairo", "clangd")
    ov, hdr, ak = os.path.join(cache, "overlay.yaml"), os.path.join(cache, "a.hh"), os.path.join(root, "a.k")
    read = lambda p: open(p).read() if os.path.exists(p) else ""
    c = Client(exe, root)
    c.start()
    ok = wait_for(lambda: os.path.exists(ov) and os.path.exists(hdr), 90, c)
    check("bridge: header and overlay written for the .k file b.cc includes", ok, os.listdir(root))
    h = read(hdr)
    lines = h.split("\n")
    at = next((i for i, l in enumerate(lines) if "add(signed int a" in l), -1)
    # P830: clangd reports physical lines, so each declaration sits on the
    # physical line it has in a.k (add: line 2), and what the emitter invents
    # is in a.hh.prelude, included from line 1.
    check("bridge: add is on the header's physical line 2, its line in a.k", at == 1, lines[:3])
    check("bridge: invented text is in the prelude, included from line 1",
          lines[0] == '#include "%s.prelude"' % hdr and "#pragma once" in read(hdr + ".prelude"), lines[:2])
    o = read(ov)
    check("bridge: overlay maps a.k to its header, external names off at the top and per entry",
          ("'name': '%s'" % ak) in o and ("'external-contents': '%s'" % hdr) in o
          and "'use-external-names': false" in o and "'use-external-name': false" in o, o)
    cd = read(os.path.join(root, ".clangd"))
    check("bridge: a .clangd fragment adds -ivfsoverlay", cd.startswith("# Written by kals") and ("-ivfsoverlay, '%s'" % ov) in cd, cd)
    mt = os.path.getmtime(ov)
    # An edit of the buffer, not saved: the header follows it.
    c.open("a.k", BR_A)
    edited = "pub fn twice(v: i32) -> i32 {\n    return v * 2\n}\n\n" + BR_A
    c.change("a.k", 2, edited)
    ok = wait_for(lambda: "twice(signed int v)" in read(hdr), 60, c)
    h2 = read(hdr).split("\n")
    at2 = next((i for i, l in enumerate(h2) if "add(signed int a" in l), -1)
    check("bridge: an unsaved edit regenerates the header, add moves to physical line 6", ok and at2 == 5, h2[:8])
    check("bridge: overlay not rewritten when the set of files did not change", os.path.getmtime(ov) == mt)
    # A buffer that does not parse keeps the last good header.
    good = read(hdr)
    c.change("a.k", 3, edited + "\npub fn broken( {\n")
    c.pump(3)
    check("bridge: a .k that does not parse keeps its last good header", read(hdr) == good)
    c.change("a.k", 4, edited)
    open(ak, "w").write(edited)
    c.pump(2)
    cl = bundled_clang(exe)
    if cl:
        r = subprocess.run([cl, "-std=c++20", "-fsyntax-only", "-ivfsoverlay", ov, "-I" + cache, os.path.join(root, "b.cc")], capture_output=True, text=True)
        check("bridge: clang resolves #include \"a.k\" through the overlay", r.returncode == 0, r.stderr[-800:])
        bad = os.path.join(root, "bad.cc")
        open(bad, "w").write('#include "a.k"\nint f() { return a::add("x", 2); }\n')
        r = subprocess.run([cl, "-std=c++20", "-fsyntax-only", "-ivfsoverlay", ov, "-I" + cache, bad], capture_output=True, text=True)
        check("bridge: clang names a.k:6 for add (#line + external names off)", ("%s:6:" % ak) in r.stderr, r.stderr[-800:])
        os.remove(bad)
    check("bridge: clean shutdown", c.stop() == 0)
    cdx = shutil.which("clangd")
    if not cdx:
        # Without clangd, what its jump reads: the physical line of add in the
        # header (0-based 5) is its line in the saved a.k.
        h3 = read(hdr).split("\n")
        at3 = next((i for i, l in enumerate(h3) if "add(signed int a" in l), -1)
        check("bridge: (no clangd) add's physical header line is its a.k line", at3 == 5, h3[:8])
        return
    d = Client(cdx, root)
    d.start()
    d.notify("textDocument/didOpen", {"textDocument": {"uri": d.uri("b.cc"), "languageId": "cpp", "version": 1, "text": BR_B}})
    l, ch = pos(BR_B, "add(", 1)
    r = d.request("textDocument/definition", d.at("b.cc", l, ch), timeout=90)
    r = r if isinstance(r, list) else ([r] if r else [])
    check("bridge: clangd's definition of a::add is in a.k, not the header",
          bool(r) and r[0].get("uri", r[0].get("targetUri")) == "file://" + ak, r)
    # clangd reports the header's physical line and ignores #line (P830):
    # the layout puts add on its a.k line (6, 0-based 5).
    line = (r[0].get("range") or r[0].get("targetSelectionRange"))["start"]["line"] if r else -1
    check("bridge: clangd's line for a::add is its a.k line (5)", line == 5, line)
    d.stop()


# P859: a .k realistic enough that its header's prelude pulls in the runtime
# (rt/*.h), a std module's C header and a standard C++ header: the case the
# tiny a.k above never reached.
BR_REAL_K = """import std::io::{
    println,
}

ffi "c++" import "vector"

pub struct Pt { var x: i32; var y: i32 }

pub class Box {
    pub var v: i32
    pub fn Box(self) = default
    pub fn Box(self, v: i32) {
        self.v = v
    }
}

pub fn is_zero(x: i32) -> bool { return x == 0 }

fn hidden(x: i32) -> bool { return false }

fn main() -> i32 {
    var vec = cxx::std::vector<Box>()
    vec.push_back(Box(10))
    println(f"{is_zero(vec[0].v)}")
    return 0
}
"""
BR_REAL_MAIN = """#include "test.k"
#include <vector>

int main() {
    std::vector<test::Box> v;
    v.push_back(test::Box(3));
    return test::is_zero(v[0].v) ? 0 : 1;
}
"""
BR_REAL_BAD = """#include "test.k"

int f() { return test::is_zero(0) + test::hidden(1); }
"""
BR_REAL_C = "int plain(void) { return 0; }\n"


def clangd_add_words(text):
    """The `Add:` words of each fragment of a .clangd, as (path regexes or
    None, words): enough YAML for what kals writes."""
    import re
    out = []
    for frag in text.split("\n---\n"):
        pm = re.search(r"PathMatch: \[(.*)\]", frag)
        ad = re.search(r"Add: \[(.*)\]", frag)
        word = lambda m: m.group(1).replace("''", "'") if m.group(1) is not None else m.group(2)
        split = lambda t: [word(m) for m in re.finditer(r"'((?:[^']|'')*)'|([^,\s]+)", t)]
        if ad:
            out.append((split(pm.group(1)) if pm else None, split(ad.group(1))))
    return out


def bridge_real(exe, base):
    """The clangd bridge on a real file (P859): the header's prelude needs
    kcc's roots (the runtime's rt/*.h, the sysroot's libc++), which the
    .clangd gives the sources that include a .k and nothing else; bundled
    clang with exactly those words and, when present, clangd itself report
    what kcc does and jump into the .k file. Then the hint for a .clangd a
    person wrote (P857): said once, and not at all when it has the flags."""
    root = os.path.realpath(os.path.join(base, "bridge_real"))
    os.makedirs(root)
    files = {"test.k": BR_REAL_K, "main.cc": BR_REAL_MAIN, "bad.cc": BR_REAL_BAD, "plain.c": BR_REAL_C}
    for n, t in files.items():
        open(os.path.join(root, n), "w").write(t)
    cache = os.path.join(root, ".kairo", "clangd")
    hdr, cdf, tk = os.path.join(cache, "test.hh"), os.path.join(root, ".clangd"), os.path.join(root, "test.k")
    read = lambda p: open(p).read() if os.path.exists(p) else ""
    c = Client(exe, root)
    c.start()
    ok = wait_for(lambda: "PathMatch" in read(cdf) and "bad" in read(cdf), 120, c)
    c.pump(1)
    check("bridge real: .clangd scopes kcc's flags to the sources that include a .k", ok, read(cdf))
    check("bridge real: the prelude needs the runtime root (rt/ includes)", '"rt/' in read(hdr + ".prelude"), read(hdr + ".prelude")[:300])
    frags = clangd_add_words(read(cdf))
    glob_w = [w for pm, ws in frags if pm is None for w in ws]
    scoped = [(pm, ws) for pm, ws in frags if pm is not None]
    pms = scoped[0][0] if scoped else []
    kw = scoped[0][1] if scoped else []
    check("bridge real: PathMatch names main.cc and bad.cc, not plain.c",
          sorted(pms) == ["bad\\.cc", "main\\.cc"], pms)
    check("bridge real: kcc's words carry a libc++ root, the runtime root and -std, no action or input",
          any(w.endswith("/c++/v1") for w in kw) and "-I" in kw and any(w.startswith("-std=") for w in kw)
          and not any(w in ("-c", "-o", "-fsyntax-only", "-x") for w in kw), kw)
    c.stop()
    cl = bundled_clang(exe)
    if cl:
        run = lambda f: subprocess.run([cl, "-fsyntax-only"] + glob_w + kw + [os.path.join(root, f)], capture_output=True, text=True, cwd=root)
        r = run("main.cc")
        check("bridge real: bundled clang accepts main.cc with the .clangd words", r.returncode == 0, r.stderr[-1500:])
        r = run("bad.cc")
        check("bridge real: bundled clang reports only test::hidden (not pub) in bad.cc",
              r.returncode != 0 and r.stderr.count("error:") == 1 and "hidden" in r.stderr, r.stderr[-1500:])
    cdx = shutil.which("clangd")
    if cdx:
        d = Client(cdx, root)
        d.start()
        for n in ("main.cc", "bad.cc", "plain.c"):
            d.notify("textDocument/didOpen", {"textDocument": {"uri": d.uri(n), "languageId": "c" if n.endswith(".c") else "cpp", "version": 1, "text": files[n]}})
        ok = wait_for(lambda: all(d.diagnostics(n) is not None for n in ("main.cc", "bad.cc", "plain.c")), 120, d)
        dm, db, dc = d.diagnostics("main.cc"), d.diagnostics("bad.cc"), d.diagnostics("plain.c")
        # Every diagnostic, not only errors: a warning from the generated
        # header or its prelude would be one kcc never gives.
        check("bridge real: clangd reports nothing in main.cc", ok and dm == [], dm)
        check("bridge real: clangd reports exactly test::hidden in bad.cc",
              db is not None and len(db) == 1 and "hidden" in db[0]["message"], db)
        check("bridge real: clangd reports nothing in plain.c (kcc's -std is scoped away)", dc == [], dc)
        kl = BR_REAL_K.split("\n")
        for needle, decl in (("is_zero(", "pub fn is_zero"), ("Box>", "pub class Box")):
            l, ch = pos(BR_REAL_MAIN, needle, 0)
            r = d.request("textDocument/definition", d.at("main.cc", l, ch), timeout=90)
            r = r if isinstance(r, list) else ([r] if r else [])
            want = next(i for i, x in enumerate(kl) if x.startswith(decl))
            got = (r[0].get("uri", r[0].get("targetUri")), (r[0].get("range") or r[0].get("targetSelectionRange"))["start"]["line"]) if r else None
            check("bridge real: clangd's definition of test::%s is test.k line %d" % (needle.rstrip("(>"), want + 1),
                  got == ("file://" + tk, want), got)
        d.stop()
    else:
        print("note: no clangd on PATH; the clangd checks of bridge real were skipped")

    # A .clangd a person wrote: never touched; the lines to add are said
    # once however many bridge passes run, and not at all when present.
    def hints_with(user_text, label, want):
        open(cdf, "w").write(user_text)
        c = Client(exe, root)
        c.start()
        c.open("test.k", BR_REAL_K)
        wait_for(lambda: False, 6, c)
        for v in (2, 3):
            c.change("test.k", v, BR_REAL_K + "\npub fn extra%d() -> i32 { return %d }\n" % (v, v))
            wait_for(lambda: ("extra%d" % v) in read(hdr), 60, c)
            c.pump(1)
        hs = [n for n in c.notes if n["method"] in ("window/logMessage", "window/showMessage")
              and "for clangd to resolve them" in n["params"]["message"]]
        c.stop()
        check("bridge real: " + label, len(hs) == want and read(cdf) == user_text, [h["params"]["message"][:300] for h in hs])
        return hs

    ov = os.path.join(cache, "overlay.yaml")
    hs = hints_with("CompileFlags:\n  Add: [-ivfsoverlay, %s]\n" % ov,
                    "an overlay-only .clangd a person wrote gets the missing lines once, over several passes", 1)
    if hs:
        msg = hs[0]["params"]["message"]
        frag = msg[msg.index(":\n") + 2:]
        hints_with("# mine\n" + frag, "a .clangd a person wrote that has every flag gets no hint", 0)


def syntax_server(exe, base):
    """The persistent syntax worker (section 11, 2a), without the server:
    answers equal the per-process pass, a newer buffer of a file supersedes
    a queued older one, and it exits at EOF."""
    f = os.path.join(base, "syn.k")
    open(f, "w").write(SHAPES)
    p = subprocess.Popen([exe, "--worker", "--syntax-server", "--"], stdin=subprocess.PIPE, stdout=subprocess.PIPE)

    def send(obj):
        b = json.dumps(obj).encode()
        p.stdin.write(b"Content-Length: %d\r\n\r\n" % len(b) + b)
        p.stdin.flush()

    def recv():
        n = None
        while True:
            l = p.stdout.readline()
            if l in (b"\r\n", b""):
                break
            if l.lower().startswith(b"content-length"):
                n = int(l.split(b":")[1])
        return json.loads(p.stdout.read(n))

    def one(text):
        tmp, out = os.path.join(base, "syn.tmp.k"), os.path.join(base, "syn.json")
        open(tmp, "w").write(text)
        subprocess.run([exe, "--worker", out, "--syntax-only", f, "--overlay", f, tmp, "--", f])
        return json.load(open(out))

    broken = SHAPES + "\npub fn broken( {\n"
    for i, text in enumerate([SHAPES, broken, SHAPES]):
        send({"id": i, "file": f, "text": text})
        a = recv()
        b = one(text)
        check("syntax server: pass %d equals the per-process pass" % i, a.pop("id") == i and a == b, (a, b))
    # One write, so both are buffered before either is parsed.
    frames = b"".join(b"Content-Length: %d\r\n\r\n" % len(b) + b for b in
                      (json.dumps(o).encode() for o in ({"id": 10, "file": f, "text": broken}, {"id": 11, "file": f, "text": SHAPES})))
    p.stdin.write(frames)
    p.stdin.flush()
    got = [recv(), recv()]
    check("syntax server: a newer buffer supersedes a queued one", got[0] == {"id": 10, "superseded": True}
          and got[1]["id"] == 11 and got[1]["parsed"], got)
    p.stdin.close()
    check("syntax server: exits at EOF", p.wait(timeout=10) == 0)


def persistent_syntax(exe, base):
    """The server's use of the persistent syntax worker (section 11, 2a):
    syntax diagnostics arrive with no debounce through it; a killed worker
    still yields that edit's diagnostics (the per-process fallback) and is
    restarted; 300 edits sent at once leave the final revision's
    diagnostics and nothing stale after them. Both debounces are 5 s, so
    only the persistent path can answer inside the 3 s waits here."""
    root = os.path.join(base, "psyn")
    os.makedirs(root)
    F = "p.k"
    good = "pub fn ok() -> i32 { return 0 }\n"
    open(os.path.join(root, F), "w").write(good)
    c = Client(exe, root)
    c.start({"syntaxDebounceMs": 5000, "debounceMs": 5000})
    c.open(F, good)
    u = c.uri(F)

    def syn_lines():
        d = c.diagnostics(F)
        return None if d is None else sorted({x["range"]["start"]["line"] for x in d if x["code"].startswith("S") and not x["code"].startswith("SC")})

    def worker():
        out = subprocess.run(["pgrep", "-P", str(c.p.pid), "-f", "syntax-server"], capture_output=True, text=True).stdout.split()
        return int(out[0]) if out else None

    def broken_at(k, n=12):
        return "".join(("pub fn bad%d( {\n" % i) if i == k else ("pub fn g%d() -> i32 { return %d }\n" % (i, i)) for i in range(n))

    t = time.time()
    c.change(F, 2, broken_at(3))
    got = wait_for(lambda: (syn_lines() or [None])[0] == 3, 3, c)
    check("persistent syntax: diagnostics with no debounce (5 s fallback debounce not waited)", got and (time.time() - t) < 3, syn_lines())
    w = worker()
    check("persistent syntax: one syntax-server child is running", w is not None, w)
    if w:
        os.kill(w, 9)
        time.sleep(0.2)
        c.change(F, 3, broken_at(7))
        check("persistent syntax: a killed worker still yields this edit's diagnostics", wait_for(lambda: (syn_lines() or [None])[0] == 7, 3, c), syn_lines())
        check("persistent syntax: the worker is restarted", wait_for(lambda: worker() not in (None, w), 3, c), worker())
        check("persistent syntax: the restart is logged", any(n["method"] == "window/logMessage" and "syntax worker" in n["params"]["message"] for n in c.notes))
    for k in range(300):
        c.change(F, 10 + k, broken_at(k % 12 if k < 299 else 11, 12))
    final_ok = wait_for(lambda: syn_lines() == [11], 3, c)
    c.pump(1.0)
    pubs = [n for n in c.notes if n["method"] == "textDocument/publishDiagnostics" and n["params"]["uri"] == u]
    last = pubs[-1]["params"]["diagnostics"] if pubs else []
    check("persistent syntax: 300 rapid edits end on the final revision's diagnostics", final_ok and sorted({x["range"]["start"]["line"] for x in last if x["code"].startswith("S")}) == [11], last[:2])
    c.stop()


def main():
    exe = find_kals()
    print("kals:", exe)
    base = tempfile.mkdtemp(prefix="kals-smoke-")
    try:
        real = os.path.join(base, "proj")
        project(real)
        t0 = time.time()
        features(exe, real, "")
        # The same workspace reached through a symlink: the editor's spelling
        # of a path and the compiler's differ, and nothing may depend on it.
        link = os.path.join(base, "link")
        os.symlink(real, link)
        features(exe, link, "symlink: ")
        crash(exe, real)
        syntax(exe, real)
        edits(exe, real)
        macros(exe, real)
        interfaces(exe, real)
        styles(exe, real)
        bridge(exe, base)
        bridge_real(exe, base)
        syntax_server(exe, base)
        persistent_syntax(exe, base)
        waiting(exe, real)
        reruns(exe, real)
        fixits(exe, real)
        print("%.1fs" % (time.time() - t0))
    finally:
        shutil.rmtree(base, ignore_errors=True)
    if failures:
        print("%d check(s) failed" % len(failures))
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
