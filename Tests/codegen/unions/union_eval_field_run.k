// A union's fields take initializers as a struct's and a class's do. An
// `eval` field whose value an `eval fn` computes is a constant (eval.mdx):
// it is defined where its thunk is, so it can size an array. A literal
// `eval` field and a `static` field are defined after the union, a nested
// union's too, and one field may carry a default.

eval fn seven() -> i32 { return 3 + 4 }

union Reg {
    var word: u32
    var real: f32
    eval WIDTH: i32 = seven()
    eval HALF: i32 = 2
}

union <T> Cell {
    var item: T
    var raw: u64
    eval SLOTS: i32 = seven() - 4
}

union Counted {
    var a: u32 = 5
    var b: f32
    static uses: i32 = 3
}

class Outer {
    union In {
        var x: i32
        static k: i32 = 9
    }
    pub var i: i32 = 0
}

fn main() -> i32 {
    var r: Reg
    r.word = 1
    var xs: [i32; Reg::WIDTH]
    xs[6] = 5
    if Reg::WIDTH != 7 || Reg::HALF != 2 { return 1 }
    if xs[6] + (r.word as i32) != 6 { return 2 }

    var c: Cell<i32>
    c.item = 3
    if Cell<i32>::SLOTS != 3 || c.item != 3 { return 3 }

    var n: Counted
    Counted::uses += 1
    if n.a != 5 || Counted::uses != 4 { return 4 }
    if Outer::In::k != 9 { return 5 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR-LABEL: CODEGEN C++: {{.*}}union_eval_field_run.k
// IR: inline constexpr const signed int Reg{{ ?}}::{{ ?}}WIDTH{{ ?}}={{ ?}}Reg{{ ?}}::{{ ?}}__kairo_init_WIDTH{{ ?}}({{ ?}})

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
