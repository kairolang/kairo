// witness/assoc_through_assoc.k -- exit 99
// A name reached through an associated type is the same lookup as one
// reached through a parameter (interfaces.md, Generic Bodies): what the
// head's bounds declare, read through what it was reached by, at any depth.
// It was SC116E ("a member of associated type 'T::Item' cannot be named
// yet") in type position and in expression position alike.
//
//  - `T::Item::Inner` as a type, Inner declared by Item's bound;
//  - `s.get().inner().show()`, a member of a member;
//  - `T::Item::Inner::make()`, a static three heads deep, through a bound
//    (BigHolder) that DERIVES the interface declaring Inner (Holder): the
//    witness is the bound's, `BigHolder_witness<...::Item>::Inner`, since
//    rows exist for the bound;
//  - `Self::Item::Inner` inside the interface itself;
//  - two conformers, so each instance reads its own Item and Inner.

interface Show {
    fn show(const self) -> i32
}

interface Make {
    static fn make() -> Self
    fn val(const self) -> i32
}

interface Holder {
    type Inner impl Show, Make
    fn inner(const self) -> Self::Inner
}

interface BigHolder derives Holder {
    fn size(const self) -> i32
}

interface Store {
    type Item impl BigHolder
    fn get(const self) -> Self::Item
    fn peek(const self) -> Self::Item::Inner
}

struct Seven {
    pub var v: i32
}
extend Seven impl Show {
    pub fn show(const self) -> i32 = self.v
}
extend Seven impl Make {
    pub static fn make() -> Seven = Seven { v: 7 }
    pub fn val(const self) -> i32 = self.v
}

class Leaf {
    pub var v: i32
    fn Leaf(self) { self.v = 2 }
    fn Leaf(self, v: i32) { self.v = v }
    static fn make() -> Leaf { return Leaf(5) }
    fn show(const self) -> i32 { return self.v * 10 }
    fn val(const self) -> i32 { return self.v }
}

class Mid impl BigHolder {
    type Inner = Seven
    fn Mid(self) { }
    fn inner(const self) -> Seven { return Seven { v: 1 } }
    fn size(const self) -> i32 { return 30 }
}

class Pod impl BigHolder {
    type Inner = Leaf
    fn Pod(self) { }
    fn inner(const self) -> Leaf { return Leaf(3) }
    fn size(const self) -> i32 { return 4 }
}

class Top impl Store {
    type Item = Mid
    fn Top(self) { }
    fn get(const self) -> Mid { return Mid() }
    fn peek(const self) -> Seven { return Seven { v: 9 } }
}

class Box impl Store {
    type Item = Pod
    fn Box(self) { }
    fn get(const self) -> Pod { return Pod() }
    fn peek(const self) -> Leaf { return Leaf(1) }
}

fn <T impl Store> build(s: T) -> i32 {
    var x: T::Item::Inner = T::Item::Inner::make()
    var y: T::Item::Inner = s.peek()
    return x.val() + s.get().inner().show() + y.show() + s.get().size()
}

fn main() -> i32 {
    // Top: 7 + 1 + 9 + 30 = 47; Box: 5 + 30 + 10 + 4 = 49; 47 + 49 + 3
    return build(Top()) + build(Box()) + 3
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: BigHolder_witness<typename{{ ?}}::{{.*}}Store_witness<T>::Item>::Inner x ={{ ?}}::{{.*}}Make_witness<typename{{ ?}}::{{.*}}BigHolder_witness<typename{{ ?}}::{{.*}}Store_witness<T>::Item>::Inner>::make();

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 99
