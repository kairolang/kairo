// A primitive's associated constant that its type does not have is an error
// at the spelling, never a substitute value (primitives.md, Limits): each
// with a note saying why the format lacks it. A name that is no limit at
// all keeps ChainBinding's "no member" error.

fn missing() {
    var a = f8e4m3::INFINITY    // E4M3FN has no infinity
    var b = bool::MAX
    var c = byte::MIN           // a byte is not a number
    var d = f256::MAX           // no fixed representation yet
    var e = i32::EPSILON        // a float limit on an integer
    var f = u256::MAX           // C++ output cannot write it yet
    var g = u256::BITS          // fine
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: primitive_limits_errors.k:7:13: error [R024E]: 'f8e4m3' has no 'INFINITY'
// CHECK-NEXT: note [I900N]: f8e4m3 is the E4M3FN format: it has no infinity, and overflow saturates to 448
// CHECK: primitive_limits_errors.k:8:13: error [R024E]: 'bool' has no 'MAX'
// CHECK: primitive_limits_errors.k:9:13: error [R024E]: 'byte' has no 'MIN'
// CHECK-NEXT: note [I900N]: a byte is not a number; it has only BITS
// CHECK: primitive_limits_errors.k:10:13: error [R024E]: 'f256' has no 'MAX'
// CHECK: primitive_limits_errors.k:11:13: error [R024E]: 'i32' has no 'EPSILON'
// CHECK-NEXT: note [I900N]: 'EPSILON' is a float limit; integers have MIN, MAX and BITS
// CHECK: primitive_limits_errors.k:12:13: error [SC001E]: 'u256::MAX' is not supported yet
// CHECK-NOT: primitive_limits_errors.k:13:

// f80 exists only where the target's long double is x87: the same P003E as
// spelling it as a type (f80_target.k).
// RUN: { %kairo %S/Inputs/primitive_limits_f80.k --type-check-only --target=aarch64-unknown-linux-gnu 2>&1 || true; } | %FileCheck %s --check-prefix=ARM64
// RUN: { %kairo %S/Inputs/primitive_limits_f80.k --type-check-only --target=x86_64-unknown-linux-gnu 2>&1 || true; } | %FileCheck %s --check-prefix=SYSV --allow-empty
// ARM64: error [P003E]: 'f80' is unavailable on 'aarch64-unknown-linux-gnu': its 'long double' is binary128, not x87
// SYSV-NOT: error

// A name that is no limit is ChainBinding's "no member" error, as before.
// RUN: { %kairo %S/Inputs/primitive_limits_nomember.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=NOMEMBER
// NOMEMBER: primitive_limits_nomember.k:2:13: error [R024E]: 'i32' is a primitive type; it has no member 'FOO'

// `i32::MAX` is an i32 as `2147483647i32` is: narrowing it is the ordinary
// conversion error, widening it is fine.
// RUN: { %kairo %S/Inputs/primitive_limits_types.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=TYPES
// TYPES: primitive_limits_types.k:2:17: error [SC028E]: cannot convert 'i32' to 'u8'
// TYPES-NOT: primitive_limits_types.k:{{[3-9]}}:
