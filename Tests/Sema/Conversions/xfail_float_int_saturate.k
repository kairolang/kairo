// Out-of-range float -> int saturates (casting.mdx, Float to integer: "Out-
// of-range values saturate instead of producing undefined behavior";
// conversion-lattice.mdx s3.1: "it is never undefined behavior"): past the
// target's maximum the result is the maximum, below its minimum the
// minimum, +-inf likewise. NaN is neither, and the spec does not name its
// result; this test asks for 0, the only saturating answer that favours
// neither end (Rust's `as`, and LLVM's fptosi.sat). That one is a decision,
// not a spec quote: if the spec picks otherwise, change its two checks.
//
// XFAIL: *
// Ticket "[Codegen] float -> int `as` is a bare static_cast: out of range is
// undefined behaviour, not saturation" (2026-10-28). EmitIR's _cast spells
// every numeric `as` as static_cast<T>(x), which is UB in C++ past the
// range. On x86_64 at -O0 cvttsd2si answers the "integer indefinite"
// 0x80000000...: 1e18 as i32 is i32 MIN, -1.0 as u8 is 255, NaN is MIN.
// The fix is a saturating helper (or __builtin-based clamp) per target
// type. Gated to x86_64 because there the failure is deterministic; on
// another ISA the UB may happen to land on the right value and XPASS.
// When it XPASSes on x86_64, delete the XFAIL line; the checks are the spec.

import std::io::println

fn id_f32(x: f32) -> f32 { return x; }
fn id_f64(x: f64) -> f64 { return x; }

fn main() -> i32 {
    var bad = 0;
    var inf = id_f64(1.0) / id_f64(0.0);
    var nan = id_f64(0.0) / id_f64(0.0);

    if (id_f64(1.0e18) as i32) != 2147483647 { println("1e18 as i32"); bad += 1; }
    if (id_f64(-1.0e18) as i32) != -2147483648 { println("-1e18 as i32"); bad += 1; }
    if (id_f64(1.0e10) as u32) != 4294967295 { println("1e10 as u32"); bad += 1; }
    if (id_f64(300.0) as u8) != 255 { println("300 as u8"); bad += 1; }
    if (id_f64(-1.0) as u8) != 0 { println("-1 as u8"); bad += 1; }
    if (id_f64(-1.0) as u64) != 0 { println("-1 as u64"); bad += 1; }
    if (id_f32(1.0e30f32) as i64) != 9223372036854775807 { println("1e30f32 as i64"); bad += 1; }
    if (inf as i64) != 9223372036854775807 { println("inf as i64"); bad += 1; }
    if (-inf as i64) != (-9223372036854775807 - 1) { println("-inf as i64"); bad += 1; }
    if (inf as u16) != 65535 { println("inf as u16"); bad += 1; }
    if (-inf as u32) != 0 { println("-inf as u32"); bad += 1; }
    if (nan as i32) != 0 { println("NaN as i32"); bad += 1; }
    if (nan as u8) != 0 { println("NaN as u8"); bad += 1; }

    println(f"bad {bad}");
    return bad;
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang, host-x86_64
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=BUILD --allow-empty
// BUILD-NOT: {{error|warning}}
// RUN: %t.exe > %t.out
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// OUT: bad 0
