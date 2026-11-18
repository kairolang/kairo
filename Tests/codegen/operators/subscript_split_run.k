// The split subscript at run time: a type that declares `op []=`
// selects a form per use, and the selected form is the one that RUNS. The
// two forms here hand out different storage -- reads see `r`, writes land
// in `w` -- so every check below observes which form a use called. Each
// check that fails returns its own number; 0 is all of them right.
//
// Rows of the split-subscript design table: plain reads (1, 2, 4, 7), writes
// (13, 15, 18), `&x[i]` on a mutable and a const container (23, 24) and
// where `*const T` is the target (25), `@inout` (26), a member written
// through (39) and read (38), method receivers taking `self` and `const
// self` (33, 34), nested subscripts read and written (41, 43), a generic
// class, and a read on a MUTABLE container with both forms declared: clang
// would pick the non-const C++ `operator[]` there, so Kairo calls each form
// by its own name (CXXSpell::operator_name).

class Two {
    var r: [i32; 4]
    var w: [i32; 4]
    fn Two(self) {
        self.r = [10, 20, 30, 40]
        self.w = [0, 0, 0, 0]
    }

    fn op [] (const self, i: usize) -> *const i32 { return &self.r[i] }
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
    fn Cells(self) {
        self.r[0].v = 7
        self.r[1].v = 8
    }

    fn op [] (const self, i: usize) -> *const Cell { return &self.r[i] }
    fn op []= (self, i: usize) -> *Cell { return &self.w[i] }
}

class <T> Grid {
    var r: [T; 2]
    var w: [T; 2]
    fn Grid(self) { }
    fn op [] (const self, i: usize) -> *const T { return &self.r[i] }
    fn op []= (self, i: usize) -> *T { return &self.w[i] }
}

fn bump_in(@inout x: i32) {
    x += 100
}

fn read_ptr(p: *const i32) -> i32 {
    return *p
}

fn main() -> i32 {
    var t = Two()
    var x = t[0]                // read: r[0]
    if x != 10 { return 1 }
    if t[1] + 1 != 21 { return 2 }

    t[0] = 5                    // write: w[0]
    if t.w[0] != 5 || t.r[0] != 10 { return 3 }

    t[1] += 2                   // compound: read and write through w[1]
    if t.w[1] != 2 || t.r[1] != 20 { return 4 }

    ++t[2]
    t[2]++
    if t.w[2] != 2 { return 5 }

    var *p = &t[3]              // mutable container: the place form
    *p = 9
    if t.w[3] != 9 { return 6 }

    const ct = Two()
    var *q = &ct[3]             // const container: the read form, *const i32
    if *q != 40 { return 7 }

    var pc: *const i32 = &t[2]  // `*const T` wanted: the read form
    if *pc != 30 { return 8 }

    bump_in(&t[0])              // @inout: the place form
    if t.w[0] != 105 { return 9 }

    if read_ptr(&ct[1]) != 20 { return 10 }

    var cs = Cells()
    cs[0].bump()                // `self` method: the place form
    if cs.w[0].v != 1 || cs.r[0].v != 7 { return 11 }
    if cs[1].get() != 8 { return 12 } // `const self` method: the read form

    cs[1].v = 3                 // a member written through: the place form
    if cs.w[1].v != 3 { return 13 }
    if cs[1].v != 8 { return 14 } // a member read: the read form

    var g = Grid<Two>()
    g[0][1] = 4                 // nested write: both place forms
    if g.w[0].w[1] != 4 { return 15 }
    if g[0][1] != 20 { return 16 } // nested read: both read forms

    var gi = Grid<i32>()
    gi[1] = 6
    if gi.w[1] != 6 || gi[1] != 0 { return 17 }

    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=TC --allow-empty
// TC-NOT: {{error|warning}}
// RUN: { %kairo %s --type-check-only --print-cxx 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-DAG: __kairo_op_get(
// CXX-DAG: __kairo_op_set(
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
