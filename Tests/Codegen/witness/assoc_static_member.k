// witness/assoc_static_member.k -- exit 52
// A static requirement named through an associated type, `T::Item::make()`,
// is the witness call `T::make()` is, with the associated type as Self:
// `Make_witness<typename Store_witness<T>::Item>::make()` (it was SC116E).
// Its `-> Self` reads back as `T::Item`, as `T::make()`'s reads as T, and so
// does a method's `-> Self` called on a value of it (`x.twice()`): the
// associated type stands for itself in the callee's signature.
// `T::Item::Made{}` / `T::Item::Made()` build a nested associated type
// through ITS constructor bound. Generic and non-generic conformers.

interface Make {
    static fn make() -> Self
    fn twice(const self) -> Self
    fn val(const self) -> i32
}

interface Default {
    fn Default(self)
    fn val(const self) -> i32
}

interface Kit {
    type Made impl Default
}

interface Store {
    type Item impl Make, Kit
}

struct Seven {
    pub var v: i32
}

class Zero {
    pub var z: i32
    fn Zero(self) { self.z = 0 }
    fn val(const self) -> i32 { return self.z + 1 }
}

extend Seven impl Make {
    pub static fn make() -> Seven = Seven { v: 7 }
    pub fn twice(const self) -> Seven = Seven { v: self.v * 2 }
    pub fn val(const self) -> i32 = self.v
}
extend Seven impl Kit {
    type Made = Zero
}

class <N> Wrap impl Make, Kit {
    type Made = Zero
    pub var n: N
    fn Wrap(self, n: N) { self.n = n }
    static fn make() -> Wrap<N> { return Wrap<N>(N()) }
    fn twice(const self) -> Wrap<N> { return Wrap<N>(self.n) }
    fn val(const self) -> i32 { return 3 }
}

class S impl Store {
    type Item = Seven
    fn S(self) { }
}

class <N> G impl Store {
    type Item = Wrap<N>
    fn G(self) { }
}

fn <T impl Store> build(s: T) -> i32 {
    var x = T::Item::make()
    var y: T::Item = x.twice()
    var a = T::Item::Made{}
    var b = T::Item::Made()
    return x.val() + y.val() + a.val() + b.val()
}

fn main() -> i32 {
    // S: 7 + 14 + 1 + 1 = 23; G<i32>: 3 + 3 + 1 + 1 = 8; + 21
    return build(S()) + build(G<i32>()) + 21
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: Make_witness<typename{{ ?}}::{{.*}}Store_witness<T>::Item>::make();

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 52
