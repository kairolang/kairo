// A MOVE value is moved wherever it is transferred, and C++ only moves an
// lvalue through a cast: passed by value, passed to a C++ `T&&`,
// initializing a variable, assigned, moved out of a field, returned from a
// field, filling a struct literal's field or a variant's payload, as the
// by-value operand of a user operator. Each is `static_cast<T&&>` in the
// C++. A bare local or parameter
// returned is left alone (C++ moves it, and a cast would cost the elision),
// and so is a temporary.

ffi "c++" import "vector"

class Str {
    pub var n: i32 = 0
    fn Str(self) { }
    fn Str(self, n: i32) { self.n = n }
    @move fn Str(self, other: Self) { self.n = other.n; other.n = 0 }
    fn op + (self, other: Str) -> i32 { return self.n + other.n }
}

class Pair { pub var a: Str  pub var b: Str }
struct Box { var s: Str }
enum Opt { Some { v: Str }, None }

fn take(s: Str) -> i32 { return s.n }
fn passthrough(s: Str) -> Str { return s }
fn first(p: Pair) -> Str { return p.a }

fn main() -> i32 {
    var r: i32 = 0
    var a = Str(1)
    r += take(a)                        // 1
    a = Str(2)
    a = passthrough(a)
    var b = a
    r += b.n * 2                        // 4
    var c = Str()
    c = b
    r += c.n * 4                        // 8
    var p = Pair()
    p.a = Str(3)
    r += take(p.a) * 8                  // 24
    p.a = Str(5)
    var q = first(p)
    r += q.n * 16                       // 80
    var v: cxx::std::vector<Str>
    v.push_back(q)
    v.push_back(Str(7))
    r += v[0].n + v[1].n                // 12
    var s1 = Str(2)
    var bx = Box { s: s1 }
    r += bx.s.n * 32                    // 64
    var s2 = Str(4)
    var o = Opt::Some { v: s2 }
    var s3 = Str(9)
    var s4 = Str(1)
    r += s3 + s4                        // 10
    return r                            // 203
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR-LABEL: CODEGEN C++: {{.*}}move_transfer.k
// IR:      ::move_transfer::Str passthrough({{ ?}}::move_transfer::Str s) noexcept {
// IR-NEXT: return s;
// IR:      ::move_transfer::Str first({{ ?}}::move_transfer::Pair p) noexcept {
// IR-NEXT: return static_cast<{{ ?}}::move_transfer::Str &&>(p.a);
// IR:      take(static_cast<{{ ?}}::move_transfer::Str &&>(a))
// IR:      (a ={{ ?}}::move_transfer::passthrough(static_cast<{{ ?}}::move_transfer::Str &&>(a)));
// IR:      ::move_transfer::Str b = static_cast<{{ ?}}::move_transfer::Str &&>(a);
// IR:      (c = static_cast<{{ ?}}::move_transfer::Str &&>(b));
// IR:      take(static_cast<{{ ?}}::move_transfer::Str &&>(p.a))
// IR:      first(static_cast<{{ ?}}::move_transfer::Pair &&>(p))
// IR:      v.push_back(static_cast<{{ ?}}::move_transfer::Str &&>(q));
// IR-NEXT: v.push_back({{ ?}}::move_transfer::Str(7));
// IR:      .s = static_cast<{{ ?}}::move_transfer::Str &&>(s1)
// IR:      static_cast<{{ ?}}::move_transfer::Str &&>(s2)
// IR:      s3.operator +(static_cast<{{ ?}}::move_transfer::Str &&>(s4))

// REQUIRES: clang
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s -c --cache-dir %t.d/k
// RUN: %clangxx %t.d/k/*.o %t.d/k/builtin/*.o %t.d/k/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 203
