// Two corners of split-subscript selection, observed at run time
// (the forms hand out different storage, so each check sees which form ran):
//
//   - The forms are per index type. A use that only prefers the place form
//     (`var t = b[0..2]`, `for e in b[...]`, a method receiver, `&b[k]`)
//     takes it only where an `op []=` takes the index; with a read form for
//     that index and no place form it reads, rather than failing on
//     `op []=`. A write has no such fallback.
//   - A receiver mark reaches every subscript of the receiver's path, and
//     every one is settled: `h[0].cells[1].get()` reads `h[0]` through the
//     read form (the inner `[1]` is a builtin array index), and a `fn` value
//     called through a field of an element (`fs[0].cb()`) reads it too.

class Cell {
    var v: i32
    fn Cell(self) { self.v = 0 }
    fn get(const self) -> i32 { return self.v }
}

class B {
    var d: [i32; 4]
    var e: [i32; 4]
    var c: Cell
    fn B(self) {
        self.d = [1, 2, 3, 4]
        self.e = [5, 6, 7, 8]
        self.c.v = 9
    }

    fn op [] (const self, i: usize) -> *const i32 { return &self.e[i] }
    fn op []= (self, i: usize) -> *i32 { return &self.d[i] }
    fn op [] (self, r: Range<usize>) -> [i32;] { return self.e[r.begin..r.end] }
    fn op [] (const self, k: i64) -> *const Cell { return &self.c }
}

class Holder {
    var cells: [Cell; 2]
    fn Holder(self) { self.cells[1].v = 3 }
}

class Hs {
    var r: [Holder; 1]
    var w: [Holder; 1]
    fn Hs(self) { }
    fn op [] (const self, i: usize) -> *const Holder { return &self.r[i] }
    fn op []= (self, i: usize) -> *Holder { return &self.w[i] }
}

fn seven() -> i32 { return 7 }

class F {
    var cb: fn () -> i32
    fn F(self) { self.cb = seven }
}

class Fs {
    var r: [F; 1]
    var w: [F; 1]
    fn Fs(self) { }
    fn op [] (const self, i: usize) -> *const F { return &self.r[i] }
    fn op []= (self, i: usize) -> *F { return &self.w[i] }
}

fn main() -> i32 {
    var b = B()
    var t = b[0..2]                 // no place form takes a range: the read form
    if t[0] != 5 { return 1 }
    var n = 0
    for x in b[1..3] {
        n += x
    }

    if n != 13 { return 2 }
    if b[1 as i64].get() != 9 { return 3 } // an i64 receiver: the read form
    var *pc = &b[2 as i64]          // `&` with no place form for i64: *const Cell
    if pc->v != 9 { return 4 }
    b[0] = 4                        // a usize write: the place form
    if b.d[0] != 4 { return 5 }

    var h = Hs()
    h.w[0].cells[1].v = 1
    if h[0].cells[1].get() != 3 { return 6 }

    var fs = Fs()
    if fs[0].cb() != 7 { return 7 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=TC --allow-empty
// TC-NOT: {{error|warning}}
// RUN: { %kairo %s --print-ir -o %t.ir.exe 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR-DAG: Slice<signed int> t = b.__kairo_op_get(
// IR-DAG: b.__kairo_op_get(static_cast<signed long>(1)).get()
// IR-DAG: (b.__kairo_op_set(0) = 4)
// IR-DAG: h.__kairo_op_get(0).cells[1].get()
// IR-DAG: fs.__kairo_op_get(0).cb()
// IR-NOT: h.__kairo_op_set(0).cells
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
