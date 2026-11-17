// The declaration rules of the setter form of `op []=`. The return type
// tells the two forms of `op []=` apart: with none it is the setter, which
// takes the index and the value; with one it is the place form, which takes
// the index.
//
//   - The setter takes `self`, one index and the value; the value by value
//     or `const`.
//   - An `op []=` that returns something and takes a value is neither form.
//   - For one index type the setter's value is the element the read form
//     and the place form hand out, up to `const`.
//   - It is member-only, as the place form is.
//   - `Good`, `Late` (a body-less declaration defined out of line), `Gen`
//     (a generic class, `const` index and value) and `Keys` (setters over
//     two index types beside one place form) produce nothing.

class Good {
    var d: [i32; 4]
    fn op [] (const self, i: usize) -> *const i32 { return &self.d[i] }
    fn op []= (self, i: usize) -> *i32 { return &self.d[i] }
    fn op []= (self, const i: usize, v: i32) { self.d[i] = v }
}

class Late {
    var d: [i32; 4]
    fn op []= (self, const k: usize, v: i32)
}

fn Late::op []= (self, const k: usize, v: i32) { self.d[k] = v }

class <T> Gen {
    var d: [T; 4]
    fn op [] (const self, i: usize) -> *const T { return &self.d[i] }
    fn op []= (self, i: usize) -> *T { return &self.d[i] }
    fn op []= (self, const i: usize, const v: T) { self.d[i] = v }
}

class Keys {
    var d: [i32; 4]
    fn op [] (const self, i: usize) -> *const i32 { return &self.d[i] }
    fn op []= (self, i: usize) -> *i32 { return &self.d[i] }
    fn op []= (self, i: usize, v: i32) { self.d[i] = v }
    fn op []= (self, k: Good, v: i64) { }
}

class ConstSelf {
    var d: [i32; 4]
    fn op []= (const self, i: usize, v: i32) { }
}

class Returns {
    var d: [i32; 4]
    fn op []= (self, i: usize, v: i32) -> *i32 { return &self.d[i] }
}

class TwoIndex {
    var d: [i32; 4]
    fn op []= (self, i: usize, j: usize, v: i32) { }
}

class ReadDisagrees {
    var d: [i32; 4]
    fn op [] (const self, i: usize) -> *const i32 { return &self.d[i] }
    fn op []= (self, i: usize, v: i64) { }
}

class PlaceDisagrees {
    var d: [i32; 4]
    fn op []= (self, i: usize) -> *i32 { return &self.d[i] }
    fn op []= (self, i: usize, v: i64) { }
}

class InoutValue {
    var d: [i32; 4]
    fn op []= (self, i: usize, @inout v: i32) { }
}

class Ext {
    var d: [i32; 4]
}

extend Ext {
    fn op []= (self, i: usize, v: i32) { }
}

fn op []= (e: Ext, i: usize, v: i32) { }

fn main() -> i32 {
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } > %t.diag
// RUN: %FileCheck %s --check-prefix=GOOD --allow-empty < %t.diag
// GOOD-NOT: subscript_setter_signatures.k:{{(1[6-9]|[23][0-9]|4[0-3])}}:{{.*}}error
// RUN: %FileCheck %s --check-prefix=DIAG < %t.diag
// DIAG-DAG: subscript_setter_signatures.k:47:16: error [SC280E]: 'op []=' takes 'self': the setter stores into the container, and a 'const self' setter is not supported
// DIAG-DAG: subscript_setter_signatures.k:52:5: error [SC280E]: 'op []=' with a value parameter is the setter form, which returns nothing; the place form takes only the index, 'fn op []= (self, k: K) -> *V'
// DIAG-DAG: subscript_setter_signatures.k:57:5: error [SC280E]: the setter form of 'op []=' takes one index and the value, '(self, k: K, v: V)', not 3 operands
// DIAG-DAG: subscript_setter_signatures.k:63:5: error [SC280E]: 'op []' and the setter form of 'op []=' taking 'usize' disagree on the element: 'i32' and 'i64'; the setter stores the element the other forms hand out
// DIAG-DAG: subscript_setter_signatures.k:62:5: note [SC280N]: the read form is declared here
// DIAG-DAG: subscript_setter_signatures.k:69:5: error [SC280E]: the place form and the setter form of 'op []=' taking 'usize' disagree on the element: 'i32' and 'i64'; the setter stores the element the other forms hand out
// DIAG-DAG: subscript_setter_signatures.k:68:5: note [SC280N]: the place form is declared here
// DIAG-DAG: subscript_setter_signatures.k:74:{{[0-9]+}}: error [SC280E]: the setter form of 'op []=' takes its value by value or 'const': the right side of an assignment is passed as written
// DIAG-DAG: subscript_setter_signatures.k:82:5: error [SC055E]: 'op []=' cannot be declared in an extension; it must be a member, so declare it in the type's body
// DIAG-DAG: subscript_setter_signatures.k:85:1: error [SC055E]: 'op []=' cannot be a free function; it must be a member, so declare it in the type's body
// RUN: %FileCheck %s --check-prefix=COUNT < %t.diag
// COUNT-COUNT-8: error [
// COUNT-NOT: error [
