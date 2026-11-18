// `L<T>::P` inside GENERIC code (GH#91): a parameter of that type deduces T
// from the enclosing instance of the argument (`first(l.make(3))` is T :=
// i32), and in the body it is the dependent member type, spelled
// `typename ::ns::L<T>::P` in C++. A generic class holds one as a field.

class <K> L {
    pub struct P {
        pub var k: K
    }
    pub fn L(self) { }
    pub fn make(self, k: K) -> Self::P { return Self::P { k: k } }
}

fn <T> first(r: L<T>::P) -> T { return r.k }

fn <T> wrap(v: T) -> L<T>::P {
    var p: L<T>::P = L<T>::P { k: v }
    return p
}

class <T> Keeper {
    pub var p: L<T>::P
    pub fn get(const self) -> T { return self.p.k }
}

fn main() -> i32 {
    var l = L<i32>()
    var a: i32 = first(l.make(3))                  // 3
    var big: i64 = 40
    var w: L<i64>::P = wrap(big)
    var b: i64 = first(w)                          // 40
    var c = Keeper<i32> { p: l.make(7) }
    return a + (b as i32) + c.get()                // 50
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: template<class T> T first(typename{{ ?}}::generic_nested_deduce::L<T>::P r) noexcept;

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 50
