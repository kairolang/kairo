// A function returning a nullable 64-bit scalar, a struct field of one, and
// the null check and `??` on each, compile and run on a target where a
// 64-bit scalar is 4-aligned.

fn f(n: i32) -> u64? { if n == 0 { return null } return 5000000000u64 }
fn g(n: i32) -> i64? { if n == 0 { return null } return -5000000000i64 }
fn h(n: i32) -> f64? { if n == 0 { return null } return 2.5 }
struct P { var a: u64?  var b: i32 }

fn main() -> i32 {
    var p = P { a: f(1), b: 3 }
    var bad = 0
    if f(0) != null { bad = bad + 1 }
    if (f(1) ?? 0) != 5000000000u64 { bad = bad + 2 }
    if (g(1) ?? 0) != -5000000000i64 { bad = bad + 4 }
    if (h(1) ?? 0.0) != 2.5 { bad = bad + 8 }
    if h(0) != null || g(0) != null { bad = bad + 16 }
    if (p.a ?? 0) != 5000000000u64 || p.b != 3 { bad = bad + 32 }
    return bad
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang, sysroot-i686-linux-musl
// RUN: rm -rf %t.d %t.e
// RUN: %kairo %s --target=i686-linux-musl -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %kairo %s --target=i686-linux-musl -O2 -o %t.o2.exe --cache-dir %t.e
// RUN: %t.o2.exe
