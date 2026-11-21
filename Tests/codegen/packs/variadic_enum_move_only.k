// An instance of a variadic enum whose pack holds an element that cannot be
// copied (`Outcome<i32, string, f64>`) cannot be copied either: its facts
// are its elements', so a transfer of it moves, and its last use moves --
// into a local, into a by-value parameter, through a generic function over
// the pack. An instance of copyable elements still copies.

enum <T, ...E> Outcome {
    Ok  { value: T },
    Err { error: E }...,
}

fn describe(o: Outcome<i32, string, f64>) -> i32 = match o {
    case .Ok(var value)            => value
    case .Err(const error: string) => error.size() as i32
    case .Err(var error: f64)      => 100
}

fn plain(o: Outcome<i32, f64, bool>) -> i32 = match o {
    case .Ok(var value)       => value
    case .Err(var error: f64) => 50
    case .Err(var error: bool) => 60
}

fn <...E> relay(o: Outcome<i32, E...>) -> Outcome<i32, E...> {
    var kept = o
    return kept
}

fn main() -> i32 {
    var b: Outcome<i32, string, f64> = .Err { error: "hello" }
    var c = b                                      // moves b
    var r = describe(c)                            // 5, moves c
    var d: Outcome<i32, string, f64> = .Err { error: "abc" }
    r += describe(relay(d))                        // 3
    var p: Outcome<i32, f64, bool> = .Err { error: 1.5 }
    var q = p                                      // copies p
    r += plain(p) + plain(q)                       // 50 + 50
    return r - 100                                 // 8
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe; test $? -eq 8
