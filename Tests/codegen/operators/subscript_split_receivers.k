// A split subscript as a method receiver: `x[i].m()` is typed with
// the place form while `m` is unknown, and keeps it only if the chosen `m`
// takes `self` and reaches the element itself (MemberTyping::
// settle_receiver_subscript); otherwise the use is a read and moves to the
// read form. As in subscript_split_run.k the forms hand out different
// storage, so each check observes which form ran.
//
//   - `cs[0].bump()` (`self`): the place form; `cs[1].get()` (`const self`):
//     the read form (rows 33, 34).
//   - `ps[0]->bump()` where the element is a pointer: the method's object is
//     the pointee, so the element is only read: the read form (row 44).
//   - Nested: `g[0][1].bump()` writes both levels' place forms;
//     `g[1][0].get()` reads both levels (rows 41, 43 for receivers).
//   - A `self` method on a member path, `rs[0].c.bump()`: the place form.
//   - `for e in qs[0]`: the iterable is the receiver of its `op in`, which
//     takes `self` here: the place form (row 37); `for e in vs[0..2]` over
//     a slice (no user `op in`) reads.

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
        self.r[1].v = 8
    }

    fn op [] (const self, i: usize) -> *const Cell { return &self.r[i] }
    fn op []= (self, i: usize) -> *Cell { return &self.w[i] }
}

class Ptrs {
    var a: Cell
    var b: Cell
    var r: [*Cell; 1]
    var w: [*Cell; 1]
    fn Ptrs(self) {
        self.r[0] = &self.a
        self.w[0] = &self.b
    }

    fn op [] (const self, i: usize) -> *const *Cell { return &self.r[i] }
    fn op []= (self, i: usize) -> **Cell { return &self.w[i] }
}

class <T> Grid {
    var r: [T; 2]
    var w: [T; 2]
    fn Grid(self) { }
    fn op [] (const self, i: usize) -> *const T { return &self.r[i] }
    fn op []= (self, i: usize) -> *T { return &self.w[i] }
}

class Wrap {
    var c: Cell
    fn Wrap(self) { }
}

class Wraps {
    var r: [Wrap; 1]
    var w: [Wrap; 1]
    fn Wraps(self) { }
    fn op [] (const self, i: usize) -> *const Wrap { return &self.r[i] }
    fn op []= (self, i: usize) -> *Wrap { return &self.w[i] }
}

class Seq {
    var d: [i32; 2]
    fn Seq(self) { self.d = [0, 0] }
    fn op in (self) -> yield i32 {
        for x in self.d {
            yield x
        }
    }
}

class Seqs {
    var r: [Seq; 1]
    var w: [Seq; 1]
    fn Seqs(self) {
        self.r[0].d[0] = 1
        self.r[0].d[1] = 2
        self.w[0].d[0] = 3
        self.w[0].d[1] = 4
    }

    fn op [] (const self, i: usize) -> *const Seq { return &self.r[i] }
    fn op []= (self, i: usize) -> *Seq { return &self.w[i] }
}

class Views {
    var d: [i32; 2]
    var e: [i32; 2]
    fn Views(self) {
        self.d = [1, 1]
        self.e = [5, 5]
    }

    fn op [] (self, r: Range<usize>) -> [i32;] { return self.e[r.begin..r.end] }
    fn op []= (self, r: Range<usize>) -> [i32;] { return self.d[r.begin..r.end] }
}

fn main() -> i32 {
    var cs = Cells()
    cs[0].bump()
    if cs.w[0].v != 1 || cs.r[0].v != 0 { return 1 }
    if cs[1].get() != 8 { return 2 }

    var ps = Ptrs()
    ps[0]->bump()
    if ps.a.v != 1 || ps.b.v != 0 { return 3 }

    var g = Grid<Cells>()
    g[0][1].bump()
    if g.w[0].w[1].v != 1 || g.r[0].r[1].v != 8 { return 4 }
    if g[1][0].get() != 0 { return 5 }

    var rs = Wraps()
    rs[0].c.bump()
    if rs.w[0].c.v != 1 || rs.r[0].c.v != 0 { return 6 }

    var qs = Seqs()
    var sum = 0
    for e in qs[0] {
        sum += e
    }

    if sum != 7 { return 7 }
    var vs = Views()
    var vsum = 0
    for e in vs[0..2] {
        vsum += e
    }

    if vsum != 10 { return 8 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=TC --allow-empty
// TC-NOT: {{error|warning}}
// RUN: { %kairo %s --print-ir -o %t.ir.exe 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR-DAG: cs.__kairo_op_set(0).bump()
// IR-DAG: cs.__kairo_op_get(1).get()
// IR-DAG: ps.__kairo_op_get(0)->bump()
// IR-DAG: g.__kairo_op_set(0).__kairo_op_set(1).bump()
// IR-DAG: g.__kairo_op_get(1).__kairo_op_get(0).get()
// IR-DAG: rs.__kairo_op_set(0).c.bump()
// IR-DAG: qs.__kairo_op_set(0)
// IR-DAG: vs.__kairo_op_get(
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
