// witness/assoc_ops.k -- exit 23
// An operator on values of an associated type is its bounds' requirement,
// called through the associated type's witness, as one on a bounded
// parameter is (interfaces.md, Generic Bodies): `a == b` and `a != b`
// (derived from `op ==`) on `T::Key` with `type Key impl Eq`, and `x + y`
// on `T::Item` with `type Item impl Add`. It used to be left to C++.

interface Eq { fn op ==(const self, o: Self) -> bool }
interface Add { fn op +(const self, o: Self) -> Self  fn get(const self) -> i32 }

interface Store {
    type Key impl Eq
    type Item impl Add
    fn key(const self, i: i32) -> Self::Key
    fn item(const self, i: i32) -> Self::Item
}

struct Id { pub var n: i32 }
extend Id impl Eq { fn op ==(const self, o: Id) -> bool { return self.n == o.n } }
struct Amt { pub var v: i32 }
extend Amt impl Add {
    fn op +(const self, o: Amt) -> Amt { return Amt { v: self.v + o.v } }
    fn get(const self) -> i32 { return self.v }
}

class Shop impl Store {
    type Key = Id
    type Item = Amt
    fn Shop(self) { }
    fn key(const self, i: i32) -> Id { return Id { n: i } }
    fn item(const self, i: i32) -> Amt { return Amt { v: i } }
}

fn <T impl Store> tally(s: T) -> i32 {
    var r = 0
    if s.key(1) == s.key(1) { r = r + 1 }
    if s.key(1) != s.key(2) { r = r + 2 }
    var x = s.item(5)
    var y = s.item(15)
    return r + (x + y).get()
}

fn main() -> i32 { return tally(Shop()) }   // 3 + 20

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: Eq_witness<typename{{ ?}}::{{.*}}Store_witness<T>::Key>::

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 23
