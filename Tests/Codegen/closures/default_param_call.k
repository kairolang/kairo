// A call through a local built from a closure literal takes the closure's
// default for each trailing argument it omits (closures.md, Default
// Parameters: "matching the behavior of regular functions"). The `fn` type
// the call is checked against carries no defaults, so `g(1)` was SC099E
// "takes 2 argument(s), 1 given" (the self-host's Lexer.k test harness,
// `dump_tokens(..., text: string = "none provided")`, 69 sites).

fn main() -> i32 {
    var g = fn (a: i32, b: i32 = 4, s: string = "xy") -> i32 { return a + b + (s.length() as i32) }
    var r = g(1)          // 1 + 4 + 2
    r += g(1, 10)         // 1 + 10 + 2
    r += g(1, 1, "abc")   // 1 + 1 + 3
    return r              // 7 + 13 + 5
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error [

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 25
