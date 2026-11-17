// On armv7 (AAPCS) a `u64` or `f64` record member is 8-aligned: Kairo's
// predicted layouts follow the target's alignment as clang gives it, not
// the pointer width.
struct S { var a: u8; var b: u64 }
struct D { var a: u8; var b: f64 }
enum E { A { x: u64 }, B }
enum <T> G { A { x: T }, B }

eval if sizeof S == 12 { fn rec() -> i32 = 12 } else { fn rec() -> i32 = 16 }
eval if sizeof D == 12 { fn dbl() -> i32 = 12 } else { fn dbl() -> i32 = 16 }
eval if alignof u64 == 4 { fn al() -> i32 = 4 } else { fn al() -> i32 = 8 }

fn nu() -> u64? { return null }
fn ni() -> i64? { return null }
fn nf() -> f64? { return null }
fn en() -> E { return E::B }
fn gen() -> G<u64> { return G<u64>::B }

type P = (u8, u64)

// Kairo predicts no tuple layout, so this one is `if constexpr`, clang's.
fn tup() -> i32 {
    eval if sizeof P == 12 { return 12 } else { return 16 }
}

fn main() -> i32 {
    var a = nu()
    var b = ni()
    var c = nf()
    var e = en()
    var g = gen()
    return rec() + dbl() + al() + tup()
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-armv7-linux-musl
// RUN: rm -rf %t.d
// RUN: %kairo %s --target armv7-linux-musl -c -o %t.o --cache-dir %t.d
// RUN: { %kairo %s --target armv7-linux-musl --print-ir -c -o /dev/null --cache-dir %t.d 2>&1 || true; } | %FileCheck %s
// CHECK-LABEL: rec() noexcept {
// CHECK-NEXT: return 16;
// CHECK-LABEL: dbl() noexcept {
// CHECK-NEXT: return 16;
// CHECK-LABEL: al() noexcept {
// CHECK-NEXT: return 8;
