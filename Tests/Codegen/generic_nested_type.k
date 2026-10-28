// A type nested in a generic class, used by that class: as a field, as a
// method's parameter and return type, built in a method body, and as a
// field of a second nested type. Qualified the way a top-level type is,
// `::generic_nested_type::L::P` names the class template without its
// arguments and clang rejects it ("use of class template ... requires
// template arguments"). Inside the class body the leaf is used; in the
// out-of-line member definitions, and in a sibling nested type's body, it
// is the dependent member `typename ...::L<K>::P`.
//
// `main` names `L<i32>::P` itself too (GH#91): the local carries L's
// arguments, so `q.k` is an i32, and C++ spells it `::...::L<int>::P`
// (generic_nested_instance.k has the wider shapes).

class <K> L {
    pub struct P {
        var k: K
    }
    pub struct Q {
        var x: P
        var n: i32
    }
    pub var a: P
    pub var q: Q

    pub fn L(self, k: K) {
        self.a = P { k: k }
        self.q = Q { x: P { k: k }, n: 5 }
    }

    pub fn make(self, k: K) -> P {
        return P { k: k }
    }

    pub fn get(self) -> P {
        return self.a
    }

    pub fn put(self, p: P) {
        self.a = p
    }

    pub fn val(self) -> K {
        return self.a.k
    }

    pub fn n(self) -> i32 {
        return self.q.n
    }
}

fn main() -> i32 {
    var l = L<i32>(3)
    l.put(l.get())
    l.put(l.make(9))
    var q: L<i32>::P = l.make(2)
    var k: i32 = q.k
    return l.val() + l.n() + k  // 9 + 5 + 2
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX:      template<class K> class L {
// CXX:      struct Q {
// CXX-NEXT:   typename{{ ?}}::generic_nested_type::L<K>::P x;
// CXX:      P a;
// CXX-NEXT: Q q;
// CXX:      P make(K k) noexcept;
// CXX-NEXT: P get() noexcept;
// CXX-NEXT: void put(P p) noexcept;
// CXX:      typename{{ ?}}::generic_nested_type::L<K>::P {
// CXX:      template<class K> typename{{ ?}}::generic_nested_type::L<K>::P L<K>::make(K k) noexcept {
// CXX:      template<class K> typename{{ ?}}::generic_nested_type::L<K>::P L<K>::get() noexcept {
// CXX:      template<class K> void L<K>::put(typename{{ ?}}::generic_nested_type::L<K>::P p) noexcept {
// CXX:      {{ ?}}::generic_nested_type::L<signed int>::P q = l.make(2);

// The argument-less qualified form must not appear anywhere.
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=NOQUAL
// NOQUAL-NOT: ::L::

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 16
