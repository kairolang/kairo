// A name a binder introduces is a new binding like a `const` statement's
// (variables.mdx, Shadowing): a destructuring declaration may rebind a
// `const` of its own scope, and the value it destructures still reads the
// bindings it hides. So does a `for` binder that hides the local its
// sequence names, and a pattern's binder that hides the value matched.

fn pair() -> (i32, i32) { return (3, 4) }

fn main() -> i32 {
    const (a, b) = (1, 2)
    const (a, b) = (b, a)               // reads the old a and b: a swap
    if a != 2 || b != 1 { return 1 }

    const c = 1
    const (c, d) = (c + 1, 2)           // a plain const rebound by a pattern
    if c != 2 || d != 2 { return 2 }
    const c = c + d                     // and the pattern's by a plain const
    if c != 4 { return 3 }

    const t = (5, 6)
    const (t, u) = t                    // a binder named as the tuple it takes apart
    if t != 5 || u != 6 { return 4 }

    const (p, _) = pair()
    const (p, q) = (p * 10, p)
    if p != 30 || q != 3 { return 5 }

    const xs: [i32; 3] = [1, 2, 3]
    var sum = 0
    for xs in xs { sum += xs }          // the binder hides the array it walks
    if sum != 6 { return 6 }

    const n = 3
    var steps = 0
    for n in 0..n {                     // both loops' bounds read the binding outside
        for n in 0..n { steps += 1 }
    }
    if steps != 3 { return 7 }

    const m = (7, 8)
    match m {
        case (const m, const k) {
            if m != 7 || k != 8 { return 8 }
        }
    }

    var r = 0
    if r == 0 {
        const (a, b) = (a + 10, b + 10) // an inner scope's pattern over the outer one's
        r = a + b
    }
    if r != 23 || a != 2 { return 9 }

    const f = fn () -> i32 {
        const (a, r) = (a + 1, 1)
        return a + r
    }
    if f() != 4 { return 10 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
