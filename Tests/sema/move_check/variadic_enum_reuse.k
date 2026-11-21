// A variadic enum instance whose pack holds a string cannot be copied, so a
// transfer of it moves and a later read is a use after move (SC052E), in a
// concrete body and, per instance, in a generic one over the pack. The same
// code over copyable elements is accepted.

enum <T, ...E> Outcome {
    Ok  { value: T },
    Err { error: E }...,
}

fn size_of(const o: Outcome<i32, string, f64>) -> i32 = match o {
    case .Err(const error: string) => error.size() as i32
    default                        => 0
}

fn reuse() -> i32 {
    var b: Outcome<i32, string, f64> = .Err { error: "hello" }
    var c = b
    return size_of(b) + size_of(c)
}

fn <...E> twice(o: Outcome<i32, E...>) -> i32 {
    var a = o
    var b = o
    return 2
}

fn main() -> i32 {
    var p: Outcome<i32, f64, bool> = .Err { error: 1.5 }
    var q: Outcome<i32, string, f64> = .Err { error: "x" }
    return reuse() + twice(p) + twice(q)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK:      variadic_enum_reuse.k:19:20: error [SC052E]: 'b' is used after being moved
// CHECK-NEXT: variadic_enum_reuse.k:18:13: note [I900N]: 'b' was moved here, into 'c'
// CHECK:      variadic_enum_reuse.k:31:33: error [SC052E]: 'o' is used after being moved in 'twice<string, f64>': 'Outcome<i32, string, f64>' cannot be copied, so the transfer moves it
// CHECK-NEXT: variadic_enum_reuse.k:23:13: note [I900N]: 'o' was moved here, as a 'Outcome<i32, string, f64>'
// CHECK-NEXT: variadic_enum_reuse.k:24:13: note [I900N]: and used again here
