// The setter form of `op []=`, `fn op []= (self, k: K, v: V)`: which uses
// select it, and the errors of a type that declares it without a place form.
//
//   - A plain `x[k] = v` statement selects the setter; every other use
//     selects as it does without one. The good uses at the top produce
//     nothing, on a type with all three forms, on one with a read form and
//     a setter, and through a bound that requires the setter.
//   - A use that needs a place on a type whose `op []=` is only the setter
//     is SC355E, with a note at the setter: a compound assignment, `++`, a
//     member written through, the container of a written nested subscript,
//     and an assignment whose result is read.
//   - `&x[k]` there takes the read form; an `@inout` parameter refuses it,
//     and the note says a place form is missing.
//   - A read through a type that declares only the setter is SC279E.
//   - A const container is SC071E, as for the place form.
//   - The value and the index convert as arguments do: a mismatch is the
//     setter's overload error.

class Two {
    var d: [i32; 4]
    fn Two(self) { }
    fn op [] (const self, i: usize) -> *const i32 { return &self.d[i] }
    fn op []= (self, i: usize) -> *i32 { return &self.d[i] }
    fn op []= (self, const i: usize, v: i32) { self.d[i] = v }
}

class SetOnly {
    var d: [i32; 4]
    fn SetOnly(self) { }
    fn op [] (const self, i: usize) -> *const i32 { return &self.d[i] }
    fn op []= (self, i: usize, v: i32) { self.d[i] = v }
}

class Cell {
    pub var v: i32
    fn Cell(self) { self.v = 0 }
    fn get(const self) -> i32 { return self.v }
}

class Cells {
    var d: [Cell; 2]
    fn Cells(self) { }
    fn op [] (const self, i: usize) -> *const Cell { return &self.d[i] }
    fn op []= (self, i: usize, v: Cell) { self.d[i] = v }
}

class Grid {
    var d: [SetOnly; 2]
    fn Grid(self) { }
    fn op [] (const self, i: usize) -> *const SetOnly { return &self.d[i] }
    fn op []= (self, i: usize, v: SetOnly) { self.d[i] = v }
}

class PutOnly {
    var d: [i32; 4]
    fn PutOnly(self) { }
    fn op []= (self, i: usize, v: i32) { self.d[i] = v }
}

interface Store {
    fn op [] (const self, i: usize) -> *const i32
    fn op []= (self, i: usize, v: i32)
}

fn inout_it(@inout x: i32) { x += 1 }

fn good(t: Two, s: SetOnly, cs: Cells) -> i32 {
    t[0] = 1
    (t[1]) = 2
    t[2] += 1
    ++t[3]
    var *p = &t[0]
    inout_it(&t[1])
    var y = (t[2] = 5)
    s[0] = 1
    var a = s[0]
    var *q = &s[1]
    cs[0] = Cell()
    return a + y + *q + cs[0].get() + cs[1].v
}

fn <S impl Store> generic_good(s: S) -> i32 {
    s[0] = 3
    return s[1]
}

fn needs_place(s: SetOnly, cs: Cells, g: Grid) {
    s[1] += 1
    ++s[1]
    cs[0].v = 1
    g[0][1] = 2
    var y = (s[1] = 5)
    inout_it(&s[2])
}

fn reads_put_only(o: PutOnly) -> i32 {
    o[0] = 1
    return o[1]
}

fn const_store() {
    const k = SetOnly()
    k[0] = 1
}

fn converts(s: SetOnly) {
    s[0] = "no"
    s["k"] = 1
    s[1] = 2 as i8
}

fn main() -> i32 {
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } > %t.diag
// RUN: %FileCheck %s --check-prefix=GOOD --allow-empty < %t.diag
// GOOD-NOT: subscript_setter_select.k:{{(6[0-9]|7[0-9]|8[0-5])}}:{{.*}}error
// RUN: %FileCheck %s --check-prefix=DIAG < %t.diag
// DIAG-DAG: subscript_setter_select.k:88:5: error [SC355E]: 's[1]' needs a place here, and 'SetOnly' declares only the setter form of 'op []='; declare the place form, 'fn op []= (self, k: K) -> *V'
// DIAG-DAG: subscript_setter_select.k:31:5: note [SC355N]: the setter form is declared here; it serves a plain 'x[k] = v' statement
// DIAG-DAG: subscript_setter_select.k:89:7: error [SC355E]: 's[1]' needs a place here, and 'SetOnly' declares only the setter form of 'op []='
// DIAG-DAG: subscript_setter_select.k:90:5: error [SC355E]: 'cs[0]' needs a place here, and 'Cells' declares only the setter form of 'op []='
// DIAG-DAG: subscript_setter_select.k:44:5: note [SC355N]: the setter form is declared here; it serves a plain 'x[k] = v' statement
// DIAG-DAG: subscript_setter_select.k:91:5: error [SC355E]: 'g[0]' needs a place here, and 'Grid' declares only the setter form of 'op []='
// DIAG-DAG: subscript_setter_select.k:92:14: error [SC355E]: 's[1]' needs a place here, and 'SetOnly' declares only the setter form of 'op []='
// DIAG-DAG: subscript_setter_select.k:93:5: error [SC063E]: no matching overload for call to 'inout_it'
// DIAG-DAG: note [I900N]: candidate not viable: parameter 'x' is '@inout' and needs a mutable lvalue of type 'i32'; got 'const i32'; its type declares only the setter form of 'op []=', so declare the place form, 'fn op []= (self, k: K) -> *V'
// DIAG-DAG: subscript_setter_select.k:98:12: error [SC279E]: 'PutOnly' declares no read subscript 'op []'; 'o[1]' here is a read
// DIAG-DAG: subscript_setter_select.k:57:5: note [SC279N]: only the setter form of 'op []=' is declared
// DIAG-DAG: subscript_setter_select.k:103:5: error [SC071E]: cannot write an element of 'k': 'k' is const, and 'op []=' takes 'self'
// DIAG-DAG: subscript_setter_select.k:107:5: error [SC063E]: no matching overload for call to 'op []='
// DIAG-DAG: note [I900N]: candidate not viable: cannot convert argument of type 'string' to parameter 'v' of type 'i32'
// DIAG-DAG: subscript_setter_select.k:108:5: error [SC063E]: no matching overload for call to 'op []='
// DIAG-DAG: note [I900N]: candidate not viable: cannot convert argument of type 'string' to parameter 'i' of type 'usize'
// RUN: %FileCheck %s --check-prefix=COUNT < %t.diag
// COUNT-COUNT-10: error [
// COUNT-NOT: error [
