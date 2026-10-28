// Chains on a bound call's result, end to end (bound_call_member.k is the
// one-step case). Each call is typed at the bound's arguments (MONO.md D0,
// Sema/ExprTyper/bound_call_result.k), so every later step binds against a
// concrete type: a field of a record result, a requirement on a `Self`
// result, a field of a generic requirement's result, and the same through a
// bound over the body's own parameter.

pub struct <W> Wrap { pub var w: W }
pub struct <A, B> Two { pub var a: A  pub var b: B }

pub interface <T> Fancy {
    fn shine(const self) -> T
    fn wrap(const self) -> Wrap<T>
    fn me(const self) -> Self
    fn <U> pair(const self, u: U) -> Two<T, U>
}

pub struct Gem { pub var v: i32 }
extend Gem impl Fancy<i32> {
    pub fn shine(const self) -> i32 = self.v
    pub fn wrap(const self) -> Wrap<i32> = Wrap<i32> { w: self.v * 2 }
    pub fn me(const self) -> Gem = Gem { v: self.v + 1 }
    pub fn <U> pair(const self, u: U) -> Two<i32, U> = Two<i32, U> { a: self.v, b: u }
}

pub fn <C impl Fancy<i32>> total(c: C) -> i32 {
    return c.wrap().w + c.me().shine() + c.me().wrap().w + c.pair(Wrap<i32> { w: 100 }).b.w
}
// `z` only deduces E: nothing else names it.
pub fn <E, C impl Fancy<E>> first(c: C, z: E) -> E { return c.me().wrap().w }

fn main() -> i32 {
    var g = Gem { v: 3 }
    return total(g) + first(g, 0)               // 6 + 4 + 8 + 100 + 8
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-NOT: internal compiler error
// CXX: signed int total(C c) noexcept {
// CXX-NEXT: return((( ::bound_call_chain::Fancy_witness<C, signed int>::wrap((& c)).w +
// CXX: E first(C c, E z) noexcept {
// CXX-NEXT: return::bound_call_chain::Fancy_witness<C, E>::wrap( ::__kairo_tmp( ::bound_call_chain::Fancy_witness<C, E>::me((& c)))).w;

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 126
