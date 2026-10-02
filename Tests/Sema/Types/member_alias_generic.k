// A type alias inside a generic record names the record's parameters, an
// alias may name another alias, a nested record sees its owner's parameters,
// and a specialization's alias reads the primary's member through its own
// parameters. The local-alias half (`fn <T> f() { type A = T }`) is in
// local_alias_generic.k: EmitIR does not emit statement-scope decls yet, so
// it cannot link.

class <T> Box {
    pub type Elem = T
    pub type Ptr  = *Elem

    var v: Elem

    pub fn Box(self, v: T) { self.v = v }
    pub fn get(self) -> Elem { return self.v }
    pub fn addr(self) -> Ptr { return &self.v }

    pub struct Inner {
        var e: T
    }
}

struct <R, ...Args> Traits { }

struct <T, ...Args> Traits<Box<T>, Args...> {
    pub type P = Box<T>::Elem
}

fn <T> twice(x: T) -> T {
    var y: T = x
    return y + x
}

fn main() -> i32 {
    var b = Box<i32>(7)
    var p = b.addr()
    var t: Traits<Box<i32>, i32>::P = 3
    return b.get() + *p + twice(t)     // 7 + 7 + 6 == 20
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: R021E
// DIAG-NOT: error

// Member aliases are erased in the emitted C++ (the canonical is spelled),
// so the shapes checked are the uses: Elem and Ptr resolved to Box's own T.
// RUN: { %kairo %s --print-cxx 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: template<class T> class Box {
// CXX:     T e;
// CXX:     T v;
// CXX:     T get();
// CXX:     T* addr();

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -c --cache-dir %t.d
// RUN: %clangxx %t.d/*.o %t.d/builtin/*.o %t.d/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 20
