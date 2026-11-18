// A literal yielded from a generator must convert to the generator's yield
// type: a string literal in a `yield i32` generator is SC028E, while the
// integer literals around it are accepted.

fn bad() -> yield i32 {
    yield 7
    yield "x"
    yield 3 + 4
}

fn main() -> i32 {
    var s = 0
    for v in bad() { s += v }
    return s
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not='error [' --implicit-check-not='I003E'
// CHECK: literal_reject.k:7:11: error [SC028E]: cannot convert 'string' to 'i32'
