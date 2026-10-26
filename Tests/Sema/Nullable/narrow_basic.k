// G11 (Compiler/Sema/NULLABLE.md 3.1-3.3, §4): the nullness analysis in
// straight-line code and conditions. A nullable place proven non-null is
// READ AS `T` where its value is needed: every `uN = <use> + 0` below is
// inferred `i32` only because the use was narrowed (without it, `i32? + 0`
// was SC066E / SC067E). Covered:
//   - 3.2, the value SETS the state: a literal (`var x? = 10`), `&n`, a
//     place copied (`var z: i32? = x`), a reassignment after `= null`; a
//     call's result needs its check;
//   - every spelling of the test in if/else: `x?`, `!x?`, `== null`,
//     `null != x`, `!(x == null)`;
//   - early exit (3.3) by `return`, `break`, `continue`, and a `-> !` call;
//   - `&&`, `||`, `!` over tests, and the `if c => a else b` expression,
//     whose proven arm is its value (`v1 : i32`);
//   - `while x?` narrowing at the top of its body;
//   - field paths rooted at a local and at a parameter, two levels deep,
//     and `self.f` in a method;
//   - a global narrowed between its check and the next call (3.8);
//   - a narrowed read through a generic `T?` (`return t` into `T`);
//   - the uses that do NOT read the value keep `T?`: `var keep = x`
//     (`keep : i32?`), a `T?` overload chosen over a `T` one.
// No diagnostic at all. The errors are Sema/Nullable/access_errors.k; the
// lowering and the run, Codegen/nullable/narrowed.k.

fn find(k: i32) -> i32? { if k > 0 { return k } return null }
fn stop() -> ! { while true { } }
fn pick(x: i32) -> i32 { return 1 }
fn pick(x: i32?) -> i32 { return 2 }
fn noop() { }

class In { pub var w: i32 = 2 }
class Mid { pub var inner: In? = null; pub fn Mid(self) { } }
struct S { pub var mid: Mid? = null; pub var n: i32? = null; }
class Box {
    pub var cache: i32? = null
    pub fn Box(self) { }
    pub fn get(self) -> i32 {
        if self.cache? { var u30 = self.cache + 0; return u30 }
        return 0
    }
}

var g: i32? = 4

fn <T> first(t: T?, d: T) -> T { if t? { return t } return d }

fn table(n0: i32) -> i32 {
    var x? = 10
    var u1 = x + 0
    var n = n0
    var p: (*i32)? = &n
    var u2 = *p + 0
    var y: i32? = null
    y = 3
    var u3 = y + 0
    var z: i32? = x
    var u4 = z + 0
    var c = find(n)
    if c? { var u5 = c + 0 }
    var keep = x
    return pick(x)
}

fn spellings(a: i32?) -> i32 {
    var r = 0
    if a? { var u6 = a + 0 }
    if !a? { r += 1 } else { var u7 = a + 0 }
    if a == null { r += 1 } else { var u8 = a + 0 }
    if null != a { var u9 = a + 0 }
    if !(a == null) { var u10 = a + 0 }
    return r
}

fn exits(b: i32?, c0: i32?, d: i32?) -> i32 {
    if !b? { return 0 }
    var u11 = b + 0
    var c = c0
    loop {
        if c? { break }
        c = find(1)
    }
    var u12 = c + 0
    for k in 0..3 {
        var e = find(k)
        if !e? { continue }
        var u13 = e + 0
    }
    if d == null { stop() }
    var u14 = d + 0
    return u11 + u12 + u14
}

fn logic(a: i32?, b: i32?) -> i32 {
    var r = 0
    if a? && b? { var u15 = a + b }
    if !a? || !b? { r += 1 } else { var u16 = a + b }
    if !(a? && b?) { return r }
    var u17 = a + b
    var t = a? && a > 4
    var v1 = if a? => a else => 0
    var w = find(3)
    while w? {
        var u18 = w + 0
        w = find(u18 - 1)
    }
    return r
}

fn paths(o: S) -> i32 {
    var s = S()
    s.mid = Mid()
    s.mid.inner = In()
    var u19 = s.mid.inner.w + 0
    s.n = 1
    var u20 = s.n + 0
    if o.n? { var u21 = o.n + 0 }
    if o.mid? { if o.mid.inner? { var u22 = o.mid.inner.w + 0 } }
    return 0
}

fn globals() -> i32 {
    if g? { var u23 = g + 0 }
    return first(g, 0)
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
// SEMA: -- inferred decls --
// SEMA-DAG: u1 : i32
// SEMA-DAG: u2 : i32
// SEMA-DAG: u3 : i32
// SEMA-DAG: u4 : i32
// SEMA-DAG: u5 : i32
// SEMA-DAG: keep : i32?
// SEMA-DAG: u6 : i32
// SEMA-DAG: u7 : i32
// SEMA-DAG: u8 : i32
// SEMA-DAG: u9 : i32
// SEMA-DAG: u10 : i32
// SEMA-DAG: u11 : i32
// SEMA-DAG: u12 : i32
// SEMA-DAG: u13 : i32
// SEMA-DAG: u14 : i32
// SEMA-DAG: u15 : i32
// SEMA-DAG: u16 : i32
// SEMA-DAG: u17 : i32
// SEMA-DAG: t : bool
// SEMA-DAG: v1 : i32
// SEMA-DAG: u18 : i32
// SEMA-DAG: u19 : i32
// SEMA-DAG: u20 : i32
// SEMA-DAG: u21 : i32
// SEMA-DAG: u22 : i32
// SEMA-DAG: u23 : i32
// SEMA-DAG: u30 : i32
