macro semi!() { ; }
macro outer!() { semi!() }

fn f() -> i32 {
    var a = 1 semi!()
    var c = 2 outer!() var d = 3
    return a + c + d
}

fn main() -> i32 { return f() - 6 }

// --- lit wiring -----------------------------------------------------------
// A `;` that a macro body produces through another macro ends the
// statement as a written one does. It reaches the parser wrapped twice, and
// the terminator test unwrapped one level only, so line 6 read "expected
// expression, found ';'".
// RUN: %kairo %s --type-check-only
