// A brace initializer is accepted for a class or struct with no constructor
// at all, and the constructor call form works for one with a transfer
// constructor and an ordinary one.

class Plain {
    var x: i32 = 0
}

struct SPlain {
    var x: i32 = 0
}

class Both {
    var x: i32 = 0
    @copy fn Both(self, const other: Self) = default
    fn Both(self) = default
}

fn main() -> i32 {
    var a = Plain { x: 1 }
    var b = SPlain { x: 2 }
    var c = Both()
    return a.x + b.x - 3 + c.x
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="I003E" --allow-empty
