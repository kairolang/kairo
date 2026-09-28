// Every error the f-string typer owns, at the spec's own bytes.

struct Nope { var v: i32 }

fn <T> generic(x: T) -> string { return f"{x}" }

fn main() -> i32 {
    var x: i32 = 1
    var s = "s"
    var f: f64 = 1.0
    var a = f"{x:>4q}"
    var b = f"{x:.3}"
    var c = f"{s:+}"
    var d = f"{x:_10}"
    var e = f"{f:x}"
    var g = f"{x:}"
    var p = &x
    var h = f"{p:>4}"
    return 0
}

// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: needs a concrete type
// CHECK: invalid format spec '>4q' for a value of type 'i32'
// CHECK: invalid format spec '.3' for a value of type 'i32': precision
// CHECK: invalid format spec '+' for a value of type 'string'
// CHECK: invalid format spec '_10' for a value of type 'i32'
// CHECK: invalid format spec 'x' for a value of type 'f64'
// CHECK: invalid format spec '>4' for a value of type '*i32'
