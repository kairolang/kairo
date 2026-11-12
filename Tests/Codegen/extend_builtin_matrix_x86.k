// The two floats only some targets have, f80 and f128, as extension
// targets: one method each, called and run (extend_builtin_matrix.k has the
// rest of the builtin types).

extend f80 { pub fn probe(self) -> i32 { return 1 } }
extend f128 { pub fn probe(self) -> i32 { return 1 } }

fn main() -> i32 {
    var a: f80 = 1.0
    var b: f128 = 1.0
    return a.probe() + b.probe() - 2
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: host-x86_64
// RUN: %kairo %s -o %t && %t
