// An extension's `@implicit op as` at the sites run.k does not cover: a
// struct literal's field, list and tuple elements, a constructor and a
// method argument, a user operator's and a subscript's operand, a closure
// argument and a default argument. Each is one accepted conversion, so
// each must be a written call in the C++; a site that was missed would
// type-check here and fail in clang.

struct M { var v: i32 }
struct F { var v: i32 }
extend F { @implicit fn op as (const self) -> M { return M{v: self.v} } }
struct Holder { var m: M }
class C {
    pub var m: M
    pub fn C(self, m: M) { self.m = m }
    pub fn set(self, m: M) { self.m = m }
    pub fn op + (const self, m: M) -> i32 { return self.m.v + m.v }
    pub fn op [] (const self, m: M) -> i32 { return m.v }
}
fn dflt(m: M = F{v: 5}) -> i32 { return m.v }
fn main() -> i32 {
    var f = F{v: 1}
    var h = Holder{m: f}                 // struct literal field
    var l: [M] = [f, f]                  // list elements
    var t: (M, i32) = (f, 2)             // tuple element
    var c = C(f)                         // constructor argument
    c.set(f)                             // method argument
    var plus = c + f                     // user operator operand
    var idx = c[f]                       // subscript operand
    var cl = fn (m: M) -> i32 { return m.v }
    return h.m.v + l[0].v + l[1].v + t.0.v + c.m.v + plus + idx + cl(f) + dflt() - 14
}

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe
