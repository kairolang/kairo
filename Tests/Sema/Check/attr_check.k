// No attribute is accepted and ignored: an unknown name, a known one in a
// position it does not apply to, a bad argument, the reserved
// `@unreachable` and an attribute macro (macros are not expanded yet) are
// all errors.

@fast_call fn f() -> i32 { return 1 }
@totally_made_up fn g() -> i32 { return 2 }
@pakced struct S1 { var a: u8 }
@packed fn h() { }
@align(3) struct S2 { var a: u8 }
@align(n) struct S3 { var a: u8 }
@packed(1) struct S4 { var a: u8 }
@likely fn i() { }
@no_unwind struct S5 { var a: u8 }
@deprecated(42) fn j() { }
@no_warn(SC031W, NOPE1W, SC001E) fn k() { }
@no_warn fn l() { }

macro @trace(node: *i32) { }
@trace fn m() { }

fn body(x: i32) -> i32 {
    @likely while false { }
    @unreachable if x == 0 { return 0 }
    @align(8) if x == 1 { return 1 }
    @likely if x == 2 { return 2 }
    return 3
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK-DAG: attr_check.k:6:1: error [SC001E]: unknown attribute '@fast_call'
// CHECK-DAG: attr_check.k:7:1: error [SC001E]: unknown attribute '@totally_made_up'
// CHECK-DAG: attr_check.k:8:1: error [SC001E]: unknown attribute '@pakced'
// CHECK-DAG: note [{{[A-Z0-9]+}}]: did you mean '@packed'?
// CHECK-DAG: attr_check.k:9:1: error [SC001E]: '@packed' applies only to a class, struct or union
// CHECK-DAG: attr_check.k:10:8: error [SC001E]: '@align' expects one integer literal that is a power of two
// CHECK-DAG: attr_check.k:11:8: error [SC001E]: '@align' expects one integer literal that is a power of two
// CHECK-DAG: attr_check.k:12:1: error [SC001E]: '@packed' takes no arguments
// CHECK-DAG: attr_check.k:13:1: error [SC001E]: '@likely' applies only to an 'if' statement
// CHECK-DAG: attr_check.k:14:1: error [SC001E]: '@no_unwind' applies only to a function
// CHECK-DAG: attr_check.k:15:13: error [SC001E]: '@deprecated' takes no argument or one string literal
// CHECK-DAG: attr_check.k:16:18: error [SC001E]: '@no_warn' 'NOPE1W' is not a diagnostic code
// CHECK-DAG: attr_check.k:16:26: error [SC001E]: '@no_warn' 'SC001E' is an error; only a warning can be suppressed
// CHECK-DAG: attr_check.k:17:1: error [SC001E]: '@no_warn' expects one or more warning codes
// CHECK-DAG: attr_check.k:20:1: error [SC116E]: the attribute macro '@trace' is not yet supported: attribute macros are not expanded yet
// CHECK-DAG: attr_check.k:23:5: error [SC001E]: '@likely' applies only to an 'if' statement
// CHECK-DAG: attr_check.k:24:5: error [SC116E]: '@unreachable' is not yet supported
// CHECK-DAG: attr_check.k:25:5: error [SC001E]: '@align' does not apply to a statement
