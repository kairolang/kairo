// The user's case (MONO.md G5 tickets): a generic requirement returning the
// interface's associated type, called through the bound, its result held
// in a `var x: T::Node`, and a `T::Node` built in the body. A generic body
// builds an associated type only through a constructor its bounds promise
// (interfaces.md, Generic Bodies), so `type Node impl Default` is what
// makes `T::Node{}` and `T::Node()` legal (without it they are SC001E,
// Sema/Check/assoc_type_body_errors.k). C++ value-initializes the witness's
// member type.

interface Default { fn Default(self) }

interface Iface {
    type Node impl Default
    fn <T> foo(self, x: T) -> Self::Node
}

fn <N> baz(x: N) -> N { return x }

fn <T impl Iface> bar(y: T) -> T::Node {
    var x: T::Node = y.foo(42)
    var z = baz(T::Node{})
    var w = T::Node()
    return baz(x)
}

struct S { pub var x: i32 }

class C impl Iface {
    type Node = S
    fn <T> foo(self, x: T) -> Self::Node { return S { x: 42 } }
    pub var y: i32
}

fn main() -> i32 {
    var c: C = C { y: 10 }
    var n: S = bar(c)
    return n.x
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-NOT: internal compiler error
// CXX: typename::assoc_type_construct::Iface_witness<T>::Node x = ::assoc_type_construct::Iface_witness<T>::template foo<signed int>((& y), 42);
// CXX: typename::assoc_type_construct::Iface_witness<T>::Node z = ::assoc_type_construct::baz(typename::assoc_type_construct::Iface_witness<T>::Node {
// CXX: typename::assoc_type_construct::Iface_witness<T>::Node w = typename::assoc_type_construct::Iface_witness<T>::Node();

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 42
