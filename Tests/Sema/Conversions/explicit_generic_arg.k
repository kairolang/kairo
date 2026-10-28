// An explicit generic argument fixes T, and the call's arguments convert to
// the parameter as instantiated: `pass<i64>(x)` with x: u32 is u32 -> i64
// (W, fine), `pass<u32>(x)` with x: i32 is i32 -> u32 (E, an error), and
// the result has type T, the written one (conversion-lattice.mdx s2; the
// argument rule is the same at every call). Deduction must not overrule a
// written argument.
//
// Was XFAIL (ticket "[Sema] An explicit generic argument is overridden when
// the call could deduce it", 2026-10-28); fixed by 4c1132c9, which stops a
// call's explicit generic arguments leaking into its arguments' typing.

fn <T> pass(x: T) -> T { return x; }
fn gi() -> i32 { return 1; }
fn gu() -> u32 { return 2; }
fn gf() -> f64 { return 1.0; }

fn main() -> i32 {
    var a = pass<u32>(gi());
    var b = pass<i64>(gf());
    var c: u32 = pass<u32>(gu());
    var d: i64 = pass<i64>(gu());
    var e: bool = pass<u8>(1);
    return 0;
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } \
// RUN:   | %FileCheck %s --check-prefix=DIAG --implicit-check-not='error ['
// DIAG: explicit_generic_arg.k:18:13: error [SC063E]: no matching overload for call to 'pass'
// DIAG-NEXT: {{.*}}: note [I900N]: candidate not viable: cannot convert argument of type 'i32' to parameter 'x' of type 'u32'
// DIAG: explicit_generic_arg.k:19:13: error [SC063E]: no matching overload for call to 'pass'
// DIAG-NEXT: {{.*}}: note [I900N]: candidate not viable: cannot convert argument of type 'f64' to parameter 'x' of type 'i64'
// DIAG: explicit_generic_arg.k:22:19: error [SC028E]: cannot convert 'u8' to 'bool'; the conversion may lose value and needs an explicit 'as'
