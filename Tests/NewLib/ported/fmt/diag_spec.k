// Every format spec the type checker refuses, one hole per line, by kind of value: the code and the line. The
// grammar is `[[fill] align] ['+'] ['#'] ['0'] [width] ['.' precision] [type] | '?'` with type one of x X o b e E
// (comment above `_parse_spec` in Compiler/Sema/Type/LiteralTyping.k); SC036E is "invalid format spec: the spec after `:`
// is malformed, or asks for a presentation the value's type does not support" (`kairo --explain SC036E`).
// An integer takes no precision and no `e` / `E`; a float takes no integer base and no `#`; text (string, char, bool)
// and a record take width, alignment and precision only, and a char and a bool no precision; a byte takes width,
// alignment and `#` only; a pointer takes no spec; `-` is not a sign flag; the width is at most 65535 and the
// precision at most 65534.
// Cases from Rust library/coretests/tests/fmt/num.rs (the flag combinations Rust accepts and Kairo's grammar refuses: `{:e}` on an integer)
// Cases from the {fmt} library test/format-test.cc (the invalid-spec cases: bad type letters, missing precision, overlong width)

struct Rec {
    var n: i32
    fn op as(self) -> string { return "r" }
}

fn ints() {
    var x: i32 = 1
    var a = f"{x:.3}"
    var b = f"{x:e}"
    var c = f"{x:E}"
    var d = f"{x:q}"
    var e = f"{x:>4q}"
    var f = f"{x:5x9}"
    var g = f"{x:_10}"
    var h = f"{x:-}"
    var i = f"{x:70000}"
    var j = f"{x:65536}"
    var k = f"{x:.}"
    var l = f"{x:xx}"
    var m = f"{x:0.3}"
    var u: u64 = 1
    var n = f"{u:.0}"
    var o = f"{u:e}"
}

fn floats() {
    var f: f64 = 1.0
    var a = f"{f:x}"
    var b = f"{f:X}"
    var c = f"{f:o}"
    var d = f"{f:b}"
    var e = f"{f:#}"
    var g = f"{f:#e}"
    var h = f"{f:.}"
    var i = f"{f:.65535}"
    var j = f"{f:.70000}"
    var k = f"{f:q}"
    var s: f32 = 1.0
    var l = f"{s:x}"
    var m = f"{s:#.2}"
}

fn text() {
    var s = "s"
    var c: char = 'c'
    var t = true
    var a = f"{s:x}"
    var b = f"{s:+}"
    var d = f"{s:#}"
    var e = f"{s:0}"
    var g = f"{s:e}"
    var h = f"{s:b}"
    var i = f"{c:+}"
    var j = f"{c:#}"
    var k = f"{c:.2}"
    var l = f"{c:x}"
    var m = f"{t:.2}"
    var n = f"{t:+}"
    var o = f"{t:x}"
    var p = f"{t:#}"
}

fn bytes() {
    var b: byte = 1
    var a = f"{b:.2}"
    var c = f"{b:x}"
    var d = f"{b:+}"
    var e = f"{b:08}"
}

fn records() {
    var r = Rec { n: 1 }
    var a = f"{r:x}"
    var b = f"{r:+}"
    var c = f"{r:#}"
    var d = f"{r:0}"
    var e = f"{r:e}"
}

fn valid() {
    var x: i32 = 1
    var f: f64 = 1.0
    var s = "s"
    var c: char = 'c'
    var t = true
    var b: byte = 1
    var r = Rec { n: 1 }
    var a = f"{x:#06x}{x:+08}{x:>}{x:<<5}{x:65535}{x:}{x:?}{x:*^9}{x:+#010b}"
    var d = f"{f:+10.3e}{f:.65534}{f:E}{f:.0}{f:>12.4}{f:+}"
    var e = f"{s:*^9.3}{s:?}{s:.0}{s:→>5}{s:65535}"
    var g = f"{c:>3}{c:?}{c:😀^5}{t:<6}{t:^7}{b:#}{b:>6}{b:*<4}"
    var h = f"{r:>8.1}{r:*^9}{r:?}"
}

fn pointers() {
    var x: i32 = 1
    var p: unsafe *i32 = unsafe &x
    var np: unsafe *i32 = &null
    var a = f"{p:>4}"
    var b = f"{p:x}"
    var d = f"{p:#}"
}


// --- lit wiring ---
// REQUIRES: newlib
// RUN: { %kairo_new %s --cmax-errors=0 --type-check-only 2>&1 || true; } | %FileCheck %s
// RUN: { %kairo_new %s --cmax-errors=0 --type-check-only 2>&1 || true; } | grep -c 'error \[SC036E\]' | %FileCheck %s --check-prefix=COUNT
// COUNT: 53
// CHECK: :19:{{[0-9]+}}: error [SC036E]
// CHECK: :20:{{[0-9]+}}: error [SC036E]
// CHECK: :21:{{[0-9]+}}: error [SC036E]
// CHECK: :22:{{[0-9]+}}: error [SC036E]
// CHECK: :23:{{[0-9]+}}: error [SC036E]
// CHECK: :24:{{[0-9]+}}: error [SC036E]
// CHECK: :25:{{[0-9]+}}: error [SC036E]
// CHECK: :26:{{[0-9]+}}: error [SC036E]
// CHECK: :27:{{[0-9]+}}: error [SC036E]
// CHECK: :28:{{[0-9]+}}: error [SC036E]
// CHECK: :29:{{[0-9]+}}: error [SC036E]
// CHECK: :30:{{[0-9]+}}: error [SC036E]
// CHECK: :31:{{[0-9]+}}: error [SC036E]
// CHECK: :33:{{[0-9]+}}: error [SC036E]
// CHECK: :34:{{[0-9]+}}: error [SC036E]
// CHECK: :39:{{[0-9]+}}: error [SC036E]
// CHECK: :40:{{[0-9]+}}: error [SC036E]
// CHECK: :41:{{[0-9]+}}: error [SC036E]
// CHECK: :42:{{[0-9]+}}: error [SC036E]
// CHECK: :43:{{[0-9]+}}: error [SC036E]
// CHECK: :44:{{[0-9]+}}: error [SC036E]
// CHECK: :45:{{[0-9]+}}: error [SC036E]
// CHECK: :46:{{[0-9]+}}: error [SC036E]
// CHECK: :47:{{[0-9]+}}: error [SC036E]
// CHECK: :48:{{[0-9]+}}: error [SC036E]
// CHECK: :50:{{[0-9]+}}: error [SC036E]
// CHECK: :51:{{[0-9]+}}: error [SC036E]
// CHECK: :58:{{[0-9]+}}: error [SC036E]
// CHECK: :59:{{[0-9]+}}: error [SC036E]
// CHECK: :60:{{[0-9]+}}: error [SC036E]
// CHECK: :61:{{[0-9]+}}: error [SC036E]
// CHECK: :62:{{[0-9]+}}: error [SC036E]
// CHECK: :63:{{[0-9]+}}: error [SC036E]
// CHECK: :64:{{[0-9]+}}: error [SC036E]
// CHECK: :65:{{[0-9]+}}: error [SC036E]
// CHECK: :66:{{[0-9]+}}: error [SC036E]
// CHECK: :67:{{[0-9]+}}: error [SC036E]
// CHECK: :68:{{[0-9]+}}: error [SC036E]
// CHECK: :69:{{[0-9]+}}: error [SC036E]
// CHECK: :70:{{[0-9]+}}: error [SC036E]
// CHECK: :71:{{[0-9]+}}: error [SC036E]
// CHECK: :76:{{[0-9]+}}: error [SC036E]
// CHECK: :77:{{[0-9]+}}: error [SC036E]
// CHECK: :78:{{[0-9]+}}: error [SC036E]
// CHECK: :79:{{[0-9]+}}: error [SC036E]
// CHECK: :84:{{[0-9]+}}: error [SC036E]
// CHECK: :85:{{[0-9]+}}: error [SC036E]
// CHECK: :86:{{[0-9]+}}: error [SC036E]
// CHECK: :87:{{[0-9]+}}: error [SC036E]
// CHECK: :88:{{[0-9]+}}: error [SC036E]
// CHECK: :110:{{[0-9]+}}: error [SC036E]
// CHECK: :111:{{[0-9]+}}: error [SC036E]
// CHECK: :112:{{[0-9]+}}: error [SC036E]
