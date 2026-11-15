// `const &x` in the head of an `if`, a `while` and a `match`, in a list
// literal and in a named initializer's field: `const` there begins the
// expression, never a binding. A statement that starts with `const` is a
// declaration, so a bare `const &a` statement is the declaration error
// (its own file would stop at it; the second RUN feeds it alone).

struct S {
    var p: *const i32
}

fn main() -> i32 {
    var a = 1
    var p: *const i32 = const &a
    var n = 0
    if const &a == p {
        n += 1
    }

    while const &a != p {
        n += 100
    }

    match const &a {
        case var x => {
            n += *x
        }
    }

    var l: [*const i32] = [const &a, const &a]
    var s = S { p: const &a }
    n += *s.p + *l[1]
    return n - 4
}

// --- lit wiring ---
// RUN: rm -rf %t && mkdir -p %t
// RUN: %kairo %s -w -o %t/h.exe --cache-dir %t/c
// RUN: %t/h.exe
//
// RUN: printf 'fn main() -> i32 {\n    var a = 1\n    const &a\n    return 0\n}\n' > %t/bare.k
// RUN: { %kairo %t/bare.k --syntax-only 2>&1 || true; } | %FileCheck %s --check-prefix=BARE
// BARE: bare.k:3:5: error [S046E]: expected a name after the binding keyword
