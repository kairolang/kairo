// The writes that `const` forbids are accepted on the mutable counterparts:
// `++`, `--`, `op=` and `=` on a `var` binding, writes through a `*i32`
// parameter and through a pointer to a mutable local, and reading a const
// binding.

fn bump(c: *i32) -> i32 {
    *c += 1
    *c = *c + 1
    return 0
}

fn main() -> i32 {
    var n: i32 = 1
    ++n
    n += 2
    n--
    n = 4
    const k: i32 = 5
    var x: i32 = 0
    var s: string = "a"
    s = "x"
    var p: *i32 = &x
    *p = 2
    return bump(&x) + n + k
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty --implicit-check-not='error [' --implicit-check-not='warning ['
