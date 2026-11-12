// The declaration rules of a split subscript: a type that declares
// `op []=` has a read form, `op []`, and a place form, `op []=`.
//
//   - `op []=` takes `self` (a `const self` place form is not supported
//     yet) and returns `*T` or a mutable view `[T;]`; `*const T`, a value,
//     `unsafe *T` and no result at all are errors.
//   - `op []` beside it returns `*const T`, a value or a view; `*T` is an
//     error (a write would go through the read form).
//   - For one index type the two forms name one element, const aside.
//   - `op []=` is member-only, as `op []` is: not in an `extend` block and
//     not as a free function.
//   - A type that declares `op []=` cannot inherit a place-returning `op []`.
//
// The good shapes produce nothing: a class and a struct with the usual pair,
// a generic class, a class with only `op []=`, a value read form, a view pair
// over a range, a `self` read form taking another index type. A type with no
// `op []=` is untouched: `op [] (self) -> *T` there is today's place
// operator, no error.

class Good {
    var d: [i32; 4]
    fn Good(self) { }
    fn op [] (const self, i: usize) -> *const i32 { return &self.d[i] }
    fn op []= (self, i: usize) -> *i32 { return &self.d[i] }
    fn op [] (self, i: i64) -> i32 { return self.d[0] }
}

struct SGood {
    var d: [i32; 2]
    fn op [] (const self, i: usize) -> *const i32 { return &self.d[i] }
    fn op []= (self, i: usize) -> *i32 { return &self.d[i] }
}

class <T> GGood {
    var d: [T; 2]
    fn GGood(self) { }
    fn op [] (const self, i: usize) -> *const T { return &self.d[i] }
    fn op []= (self, i: usize) -> *T { return &self.d[i] }
}

class OnlySet {
    var d: [i32; 2]
    fn OnlySet(self) { }
    fn op []= (self, i: usize) -> *i32 { return &self.d[i] }
}

class ValueRead {
    var d: [i32; 2]
    fn ValueRead(self) { }
    fn op [] (const self, i: usize) -> i32 { return self.d[i] }
    fn op []= (self, i: usize) -> *i32 { return &self.d[i] }
}

class Legacy {
    var d: [i32; 2]
    fn Legacy(self) { }
    fn op [] (self, i: usize) -> *i32 { return &self.d[i] }
}

class ConstSelf {
    var d: [i32; 2]
    fn ConstSelf(self) { }
    fn op []= (const self, i: usize) -> *i32 { return &null }
}

class ConstPlace {
    var d: [i32; 2]
    fn ConstPlace(self) { }
    fn op []= (self, i: usize) -> *const i32 { return &self.d[i] }
}

class ValuePlace {
    var d: [i32; 2]
    fn ValuePlace(self) { }
    fn op []= (self, i: usize) -> i32 { return self.d[i] }
}

class UnsafePlace {
    var d: [i32; 2]
    fn UnsafePlace(self) { }
    fn op []= (self, i: usize) -> unsafe *i32 { return &null }
}

class NoResult {
    var d: [i32; 2]
    fn NoResult(self) { }
    fn op []= (self, i: usize) { }
}

class MutRead {
    var d: [i32; 2]
    fn MutRead(self) { }
    fn op [] (self, i: usize) -> *i32 { return &self.d[i] }
    fn op []= (self, i: usize) -> *i32 { return &self.d[i] }
}

class Disagree {
    var d: [i32; 2]
    var e: [i64; 2]
    fn Disagree(self) { }
    fn op [] (const self, i: usize) -> *const i32 { return &self.d[i] }
    fn op []= (self, i: usize) -> *i64 { return &self.e[i] }
}

extend Good {
    fn op []= (self, i: u8) -> *i32 { return &self.d[0] }
}

fn op []= (g: Good, i: u8) -> *i32 { return &null }

class Base {
    var d: [i32; 2]
    fn Base(self) { }
    fn op [] (self, i: usize) -> *i32 { return &self.d[i] }
}

class Derived derives Base {
    var e: [i32; 2]
    fn Derived(self) { }
    fn op []= (self, i: i64) -> *i32 { return &self.e[0] }
}

fn main() -> i32 {
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } > %t.diag
// RUN: %FileCheck %s --check-prefix=GOOD --allow-empty < %t.diag
// GOOD-NOT: subscript_split_signatures.k:{{(1|2|3|4|5)[0-9]}}:{{.*}}error
// RUN: %FileCheck %s --check-prefix=DIAG < %t.diag
// DIAG-DAG: subscript_split_signatures.k:63:16: error [SC280E]: 'op []=' takes 'self': it hands out the place a write goes through, and a 'const self' place form is not supported
// DIAG-DAG: fix-it:{{.*}}:{63:16-63:22}:""
// DIAG-DAG: subscript_split_signatures.k:69:5: error [SC280E]: 'op []=' returns '*const T', which cannot be written through; return '*T' (the read form, 'op []', returns '*const T')
// DIAG-DAG: subscript_split_signatures.k:75:5: error [SC280E]: 'op []=' must return the place a write goes through, '*T', or a mutable view '[T;]'; a value cannot be written through (a value subscript is 'op []')
// DIAG-DAG: subscript_split_signatures.k:81:5: error [SC114E]: 'op []=' cannot return 'unsafe *T'; a place is '*T', and an unsafe pointer is not one
// DIAG-DAG: subscript_split_signatures.k:87:5: error [SC280E]: 'op []=' must return the place a write goes through, '*T', or a mutable view '[T;]'
// DIAG-DAG: subscript_split_signatures.k:93:5: error [SC280E]: 'op []' is the read form in a type that declares 'op []=', so it returns '*const T', a value or a read-only view; '*T' would let a write go through the read form
// DIAG-DAG: subscript_split_signatures.k:94:5: note [SC280N]: 'op []=' is declared here
// DIAG-DAG: subscript_split_signatures.k:102:5: error [SC280E]: 'op []' and 'op []=' taking 'usize' disagree on the element: 'i32' and 'i64'; the two forms of one subscript hand out one element type
// DIAG-DAG: subscript_split_signatures.k:101:5: note [SC280N]: the read form is declared here
// DIAG-DAG: subscript_split_signatures.k:106:5: error [SC055E]: 'op []=' cannot be declared in an extension; it must be a member, so declare it in the type's body
// DIAG-DAG: subscript_split_signatures.k:109:1: error [SC055E]: 'op []=' cannot be a free function; it must be a member, so declare it in the type's body
// DIAG-DAG: subscript_split_signatures.k:117:1: error [SC280E]: a type that declares 'op []=' cannot inherit a place-returning 'op []' ('*T') from 'Base': that one would be a second place form
// DIAG-DAG: subscript_split_signatures.k:114:5: note [SC280N]: 'Base::op []' is declared here
// RUN: %FileCheck %s --check-prefix=COUNT < %t.diag
// COUNT-COUNT-10: error [
// COUNT-NOT: error [
