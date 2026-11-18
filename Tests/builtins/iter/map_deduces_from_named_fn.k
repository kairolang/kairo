// `map(f)` deduces its result type from a named function: Map's `f` is a
// `fn(I::Item) -> U`, and I is bound by the receiver.
import std::iter::*

fn triple(x: i32) -> i32 = x * 3
fn is_even(x: *const i32) -> bool = (*x & 1) == 0
fn half(x: i32) -> f64 = x as f64 / 2.0

pub fn chain_sum(const s: [const i32;]) -> i32 {
    return iter(s.iter()).copied().map(triple).filter(is_even).sum()
}

fn main() -> i32 {
    var v: [i32] = [1, 2, 3, 4]
    var r = chain_sum(v) - 18
    var h = iter(v.iter()).copied().map(half).sum()
    return r + (h * 2.0) as i32 - 10
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
