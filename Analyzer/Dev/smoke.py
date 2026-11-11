#!/usr/bin/env python3
"""End-to-end check of kals over stdio, on a project this script writes.

    python3 Analyzer/Dev/smoke.py [path/to/kals]

Default binary: the newest build/<triple>/{debug,release}/bin/kals. Exits 0
when every check passes; prints the failing check otherwise. It lives here and
not under Tests/ because that tree is frozen; it is the server's regression
test until a lit wrapper is approved.
"""
import glob, os, shutil, sys, tempfile, time

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
        "extension"]

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
    # The run of the valid text (older) lands now: it must not overwrite them.
    end = time.time() + 30
    older = None
    while time.time() < end and older is None:
        for n in c.notes[mark:]:
            if n["method"] == "$/kals/analysed" and n["params"]["revision"] < n["params"]["current"]:
                older = n
        c.pump(0.05)
    check("syntax pass: an older run does not overwrite the newer syntax errors", older is not None and syntax_errors(), (older, c.diagnostics(M)))
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
        waiting(exe, real)
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
