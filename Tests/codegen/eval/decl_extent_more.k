// EVAL.md §11: more declaration types C++ computes from eval items. A
// module-scope constant computed by an eval fn sizes a field (what the
// 1.2a fix-it makes of an own-class one); a dependent length in a
// template's field and a generic signature; eval fns that call each other
// (only what a body evaluates at its own definition orders it, so mutual
// recursion has an order).

eval fn two() -> i32 { return 2 }
eval fn twice(x: usize) -> usize { return x * 2 }
eval fn even(x: usize) -> bool { return x == 0 || odd(x - 1) }
eval fn odd(x: usize) -> bool { return x != 0 && even(x - 1) }
eval fn pick(x: usize) -> usize { if even(x) { return 2 } return 3 }

eval J: i32 = two()          // the 1.2a fix-it's result: J at module scope
pub class Box {
    pub var b: [i32; J]
    fn Box(self) { }
}

class <eval N: usize> Dep {
    pub var a: [i32; twice(N)]
    fn Dep(self) { }
}

class Grid2 {
    pub var cells: [i32; pick(4)]
    fn Grid2(self) { }
}

fn <eval M: usize> size_of(const d: Dep<M>) -> usize { return twice(M) }

fn main() -> i32 {
    var b = Box()
    b.b[1] = 5
    var d = Dep<3>()
    d.a[5] = 1
    var g = Grid2()
    g.cells[1] = 2
    return b.b[1] + d.a[5] + g.cells[1] + (size_of<3>(d) as i32)   // 5 + 1 + 2 + 6 == 14
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 14
