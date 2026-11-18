// Which form a use of a split subscript selects, and the errors when that
// form cannot be used . The selection
// is strict: a read never calls `op []=`, a write never calls
// `op []`.
//
//   - A read through a type that declares only `op []=` is SC279E naming
//     the type, with a note at the place form (rows 1, 34, 38, 43).
//   - A write through a const container is SC071E naming the container,
//     with the `var` fix-it on a local (rows 57, 39, 41).
//   - `&x[i]` on a const container falls back to the read form, a
//     `*const T` (row 24): fine to read through, refused by an
//     `@inout` parameter.
//   - A method taking `self` on an element of a const container is the
//     ordinary "not const" error (row 33 on a const container).
//   - A type with no `op []=` keeps today's behaviour, errors included: a
//     write through its `*const T` place is today's SC071E text.
//   - A bounded `T` resolves against the bounds' forms: a write through a
//     bound that declares only `op []` is the ordinary member error (row
//     83, legacy), one that declares `op []=` resolves (row 84).
//   - The good uses at the top produce nothing.

class Two {
    var r: [i32; 4]
    var w: [i32; 4]
    fn Two(self) { }
    fn op [] (const self, i: usize) -> *const i32 { return &self.r[i] }
    fn op []= (self, i: usize) -> *i32 { return &self.w[i] }
}

class OnlySet {
    var w: [i32; 4]
    fn OnlySet(self) { }
    fn op []= (self, i: usize) -> *i32 { return &self.w[i] }
}

class Cell {
    var v: i32
    fn Cell(self) { self.v = 0 }
    fn bump(self) { self.v += 1 }
    fn get(const self) -> i32 { return self.v }
}

class Cells {
    var r: [Cell; 2]
    var w: [Cell; 2]
    fn Cells(self) { }
    fn op [] (const self, i: usize) -> *const Cell { return &self.r[i] }
    fn op []= (self, i: usize) -> *Cell { return &self.w[i] }
}

class Legacy {
    var d: [i32; 2]
    fn Legacy(self) { }
    fn op [] (const self, i: usize) -> *const i32 { return &self.d[i] }
}

interface Store {
    fn op [] (const self, i: usize) -> *const i32
    fn op []= (self, i: usize) -> *i32
}

interface ReadOnly {
    fn op [] (const self, i: usize) -> *const i32
}

fn inout_it(@inout x: i32) { x += 1 }

fn good(t: Two, cs: Cells) -> i32 {
    var a = t[0]
    t[1] = a
    t[2] += 1
    ++t[3]
    var *p = &t[0]
    inout_it(&t[1])
    cs[0].bump()
    cs[1].v = 4
    return t[0] + cs[0].get() + cs[1].v
}

fn <S impl Store> generic_good(s: S) -> i32 {
    s[0] = 3
    return s[1]
}

fn reads_only_set(o: OnlySet) -> i32 {
    o[0] = 1
    var x = o[1]
    return o[2] + x
}

fn const_writes() {
    const ct = Two()
    ct[0] = 1
    ct[1] += 1
    var *q = &ct[2]
    var y = *q
    inout_it(&ct[3])
    const cc = Cells()
    cc[0].v = 2
    cc[1].bump()
    var z = cc[0].get()
}

fn legacy_write(l: Legacy) {
    l[0] = 1
}

fn <R impl ReadOnly> generic_ro(r: R) {
    r[0] = 3
}

fn main() -> i32 {
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } > %t.diag
// RUN: %FileCheck %s --check-prefix=GOOD --allow-empty < %t.diag
// GOOD-NOT: subscript_split_select.k:{{(6[0-9]|7[0-9]|8[0-5])}}:{{.*}}error
// RUN: %FileCheck %s --check-prefix=DIAG < %t.diag
// DIAG-DAG: subscript_split_select.k:87:13: error [SC279E]: 'OnlySet' declares no read subscript 'op []'; 'o[1]' here is a read
// DIAG-DAG: subscript_split_select.k:33:5: note [SC279N]: only the place form, 'op []=', is declared
// DIAG-DAG: subscript_split_select.k:88:12: error [SC279E]: 'OnlySet' declares no read subscript 'op []'; 'o[2]' here is a read
// DIAG-DAG: subscript_split_select.k:93:5: error [SC071E]: cannot write an element of 'ct': 'ct' is const, and 'op []=' takes 'self'
// DIAG-DAG: subscript_split_select.k:92:11: note [I900N]: 'ct' declared const here
// DIAG-DAG: fix-it:{{.*}}:{92:5-92:10}:"var"
// DIAG-DAG: subscript_split_select.k:94:5: error [SC071E]: cannot write an element of 'ct': 'ct' is const, and 'op []=' takes 'self'
// DIAG-DAG: subscript_split_select.k:97:5: error [SC063E]: no matching overload for call to 'inout_it'
// DIAG-DAG: note [I900N]: candidate not viable: parameter 'x' is '@inout' and needs a mutable lvalue of type 'i32'; got 'const i32'
// DIAG-DAG: subscript_split_select.k:99:5: error [SC071E]: cannot write an element of 'cc': 'cc' is const, and 'op []=' takes 'self'
// DIAG-DAG: subscript_split_select.k:100:5: error [SC063E]: no matching overload for call to 'bump'
// DIAG-DAG: note [I900N]: candidate not viable: 'bump' is not const; it cannot be called on a const object
// DIAG-DAG: subscript_split_select.k:105:5: error [SC071E]: cannot assign to a const place
// DIAG-DAG: subscript_split_select.k:54:5: note [I900N]: 'op []' returns a const place here
// DIAG-DAG: subscript_split_select.k:109:5: error [SC071E]: cannot assign to a const place
// RUN: %FileCheck %s --check-prefix=COUNT < %t.diag
// COUNT-COUNT-9: error [
// COUNT-NOT: error [
