// An explicit specialization is registered with its primary wherever it is
// written: directly at file scope, in a visibility group, in an `eval`
// block or in an `ffi` block. Each use below names a field only the
// specialization has.

struct <T> Box { var v: T }

struct <> Box<i8> { var a: i8 }

pub {
    struct <> Box<i16> { var b: i16 }
}

eval {
    struct <> Box<i32> { var c: i32 }
}

ffi "c++" {
    struct <> Box<i64> { var d: i64 }
}

fn main() -> i32 {
    var p = Box<i8>{ a: 1 }
    var q = Box<i16>{ b: 2 }
    var r = Box<i32>{ c: 3 }
    var s = Box<i64>{ d: 4 }
    var t = Box<u8>{ v: 5 }
    return 0
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}
