// `extend <T> View<T>` reaches `View<const X>` with T := const X, so one
// set of read members serves both element forms. The type takes its
// mutators away from a const element with a specialization, `View<const
// T>`, that declares the read forms only; the extensions apply to it as
// they do to the primary.
//
// Covered: every read member on both forms; a member that names
// `View<const T>` with T already const (the const folds: the
// specialization again); a generic member; an `impl` extension, whose bound
// a const element meets as its unqualified type does; sibling calls inside
// an extension and across two extensions; T deduced from `const U` and
// from `U` in a generic function, called before the extensions are
// declared; an operator of the bounded extension whose other operand names
// `View<const T>`, used infix in a generic body.

import std::io

interface Same {
    fn same(const self, const o: Self) -> bool
}

extend i32 impl Same {
    fn same(const self, const o: i32) -> bool { return self == o }
}

class <T> View {
    pub var p: *T
    pub var n: usize
    pub fn View(self, p: *T, n: usize) { self.p = p; self.n = n }
    pub fn set0(self, v: T) { *self.p = v }
}

class <T> View<const T> {
    pub var p: *const T
    pub var n: usize
    pub fn View(self, p: *const T, n: usize) { self.p = p; self.n = n }
    pub fn owned(const self) -> T { return *self.p }
}

fn <U> len_const(v: View<const U>) -> usize { return v.size() + v.twice() }
fn <U> len_any(v: View<U>) -> usize { return v.size() }
fn <U impl Same> has_first(v: View<const U>, const x: U) -> bool { return v.has(x) }

extend <T> View<T> {
    pub fn size(const self) -> usize { return self.n }
    pub fn twice(const self) -> usize { return self.size() * 2 }
    pub fn first(const self) -> *const T { return self.p }
    pub fn <K> tag(const self, k: K) -> K { return k }
    pub fn same_len(const self, const o: View<const T>) -> bool { return o.n == self.n }
    pub fn as_const(const self) -> View<const T> { return View<const T>(self.p, self.n) }
}

extend <T impl Same> View<T> {
    pub fn has(const self, const v: T) -> bool { return (*self.p).same(v) && self.size() > 0 }
    pub fn op == (const self, const o: View<const T>) -> bool { return (*self.p).same(*o.p) }
    pub fn twin(const self, const o: View<const T>) -> bool { return self == o }
}

fn <U impl Same> alike(a: View<const U>, b: View<const U>) -> bool { return a == b }

fn main() -> i32 {
    var k: i32 = 7
    var a = View<i32>(&k, 1)
    var c = View<const i32>(const &k, 1)
    a.set0(9)

    io::println(f"{a.size()} {c.size()} {a.twice()} {c.twice()}")
    io::println(f"{*a.first()} {*c.first()} {a.tag(3)} {c.tag(4)}")
    io::println(f"{a.same_len(c)} {c.same_len(c)} {a.as_const().owned()} {c.as_const().owned()}")
    io::println(f"{a.has(9)} {c.has(9)} {c.has(1)}")
    io::println(f"{len_const(c)} {len_any(a)} {len_any(c)} {has_first(c, 9)}")
    io::println(f"{c == c} {a == c} {c.twin(c)} {alike(c, c)}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error
// DIAG-NOT: warning

// The const of `*const T` is spelled once under T := const i32, and a
// call in a generic body spells the arguments its receiver gives the
// extension: C++ would deduce T from the `const v: T` parameter as well,
// and for `v.has(x)` on a `View<const U>` the two disagree.
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-NOT: const const
// CXX-NOT: const signed int const
// CXX: template<class __kairo_Self> struct Same_witness<const __kairo_Self>{{ ?}}: Same_witness<__kairo_Self> {
// An infix use in a generic body goes through the C++ operator, whose
// template argument is the receiver's alone:
// CXX: inline bool operator =={{ ?}}(const{{.*}}::View<T> & __kairo_a0, typename{{ ?}}::__kairo_nd<const{{.*}}::View<const T> &>::type __kairo_a1)
// CXX: return{{.*}}::__kairo_ext_View::size<U>((& v));
// CXX: return{{.*}}::__kairo_ext_View::has<const U>((& v), x);
// CXX: ::__kairo_ext_View::size<T>(self)
// CXX: ::__kairo_ext_View::size<const signed int>((& c))
// CXX: template const signed int *({{.*}}::__kairo_ext_View::first<const signed int>)(

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=BUILD --allow-empty
// BUILD-NOT: warning
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT
// OUT: 1 1 2 2
// OUT-NEXT: 9 9 3 4
// OUT-NEXT: true true 9 9
// OUT-NEXT: true true false
// OUT-NEXT: 3 1 1 true
// OUT-NEXT: true true true true
