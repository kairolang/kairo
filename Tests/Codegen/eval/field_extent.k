// An `eval` field is a class constant, and one whose initializer folds is
// an array length like an `eval` variable (EVAL.md 1.2): in a field of its
// own class, in a method, and outside the class. Each is spelled as its
// value, so C++ never has to read the constant inside the incomplete class
// (1.2a covers the one that does not fold: Sema/Eval/own_class_extent.k).

pub class Grid {
    pub eval W: i32 = 2
    pub eval CELLS: i32 = Grid::W * 3
    pub var row: [i32; W]
    pub var all: [i32; CELLS]
    fn Grid(self) {
        self.row[1] = 5
        self.all[5] = 6
    }
    fn last(self) -> i32 {
        var t: [i32; Self::W] = [7, 8]
        return t[1]
    }
}

fn main() -> i32 {
    var g = Grid()
    var outside: [i32; Grid::CELLS] = [0, 0, 0, 0, 0, 9]
    return g.row[1] + g.all[5] + g.last() + outside[5]    // 5 + 6 + 8 + 9 == 28
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR-LABEL: CODEGEN C++: {{.*}}field_extent.k
// IR:      signed int row[2] {
// IR-NEXT: };
// IR-NEXT: signed int all[6] {
// IR-NEXT: };

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 28
