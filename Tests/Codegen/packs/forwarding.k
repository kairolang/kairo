// A type pack is forwarded, not copied, at every layer (P225): `...args: T`
// is `T&&... args`, an expansion `args...` is `static_cast<T&&>(args)...`,
// and `for a in args` binds each element as an lvalue. A temporary reaches
// the last layer untouched: a MOVE value through two layers is moved once,
// by the parameter that finally owns it, and a @copy value through three
// layers into a `const` reader is never copied. An lvalue of a COPY type at
// the first call is still copied once, as any `x: T` parameter copies it.
// `const` and `@inout` packs keep their modes: `const T... xs`, and the
// pointers `&x` makes.

var moves: i32 = 0
var copies: i32 = 0

class Tok {
    pub var v: i32
    pub fn Tok(self, v: i32) { self.v = v }
    @move fn Tok(self, other: Self) { self.v = other.v; other.v = -1; moves += 1 }
    fn op delete(self) { }
}

class Counted {
    pub var v: i32
    pub fn Counted(self, v: i32) { self.v = v }
    @copy fn Counted(self, const other: Self) { self.v = other.v; copies += 1 }
}

fn take(t: Tok) -> i32 { return t.v }
fn read(const c: Counted) -> i32 { return c.v }

fn <...T> tok_inner(...args: T) -> i32 { return take(args...) }
fn <...T> tok_outer(...args: T) -> i32 { return tok_inner(args...) }

fn <...T> cnt_3(...args: T) -> i32 { return read(args...) }
fn <...T> cnt_2(...args: T) -> i32 { return cnt_3(args...) }
fn <...T> cnt_1(...args: T) -> i32 { return cnt_2(args...) }

fn <...T> count(...args: T) -> i32 {
    var n = 0
    for a in args { n += 1 }
    return n
}
fn <...T> count_const(const ...args: T) -> i32 { return count(args...) }

fn main() -> i32 {
    if tok_outer(Tok(5)) != 5 { return 1 }
    if moves != 1 { return 10 + moves }
    var h = Tok(6)
    if tok_outer(h) != 6 { return 2 }
    if moves != 2 { return 20 + moves }
    if cnt_1(Counted(7)) != 7 { return 3 }
    if copies != 0 { return 30 + copies }
    var c = Counted(8)
    if cnt_1(c) != 8 { return 4 }
    if copies != 1 { return 40 + copies }
    var x = 1
    if count(x, c, 2.0) != 3 { return 5 }
    if count_const(x, 2) != 2 { return 6 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: template<class ... T> signed int tok_inner(T && ... args) noexcept {
// CXX-NEXT: return::forwarding::take(static_cast<T &&>(args) ...);
// CXX: template<class ... T> signed int tok_outer(T && ... args) noexcept {
// CXX-NEXT: return::forwarding::tok_inner(static_cast<T &&>(args) ...);
// CXX: template<class ... T> signed int count(T && ... args) noexcept {
// CXX: (... &&[&]({{\[\[}}maybe_unused{{\]\]}} auto & a)->bool {
// CXX: (args));
// CXX: template<class ... T> signed int count_const(const T ... args) noexcept {
// CXX-NEXT: return::forwarding::count(args ...);
// CXX: ::forwarding::tok_outer<{{ ?}}::forwarding::Tok>({{ ?}}::forwarding::Tok(5))
// CXX: ::forwarding::tok_outer<{{ ?}}::forwarding::Tok>(static_cast<{{ ?}}::forwarding::Tok &&>(h))
// CXX: ::forwarding::cnt_1<{{ ?}}::forwarding::Counted>(static_cast<{{ ?}}::forwarding::Counted>(c))
// CXX: template signed int({{ ?}}::forwarding::tok_outer<{{ ?}}::forwarding::Tok>)({{ ?}}::forwarding::Tok &&);

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
