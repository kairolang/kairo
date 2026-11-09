// generics/generic_fn_value.k -- exit 0
// A generic function's instance as a value: `pick<i32>` is the function
// pointer of that instance, inferred into a `fn` variable (no "no inferred
// type" internal warning), converted into a declared one, and named
// through a module path.

pub fn <T> pick(v: T) -> T { return v }
module m { pub fn <T> wide(v: T) -> i64 { return (sizeof T) as i64 } }

fn main() -> i32 {
    var f = pick<i32>
    var g: fn(i32) -> i32 = pick<i32>
    var w = m::wide<i16>
    var s: i16 = 1
    if f(3) != 3   { return 1 }
    if g(4) != 4   { return 2 }
    if w(s) != 2 { return 3 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 >/dev/null || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning|I011W}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
