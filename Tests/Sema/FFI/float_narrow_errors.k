// An f64 converts implicitly to no integer and not to bool, on every path
// a conversion is ranked or checked: a Kairo call, an imported call, an
// imported template's non-deduced parameter, an imported operator, a
// member call on an imported container, and initialization. Implicit
// conversions only widen (casting-implicit.mdx); `as` says the rest.

ffi "c++" import "float_narrow.h"
ffi "c++" import "vector"

fn k_int(x: i64) -> i32 { return 1 }
fn k_bool(x: bool) -> i32 { return 1 }

fn main() -> i32 {
    var d: f64 = 1.5
    var b: adl::Box
    var v: cxx::std::vector<i64>
    var a1 = k_int(d)
    var a2 = k_bool(d)
    var a3 = take_ll(d)
    var a4 = take_b(d)
    var a5 = take_t(1, d)
    var a6 = b + d
    v.push_back(d)
    var e: i64 = d
    var f: bool = d
    return 0
}

// --- lit wiring -----------------------------------------------------------

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:17:14: error [SC063E]: no matching overload for call to 'k_int'
// DIAG-NEXT: {{.*}}:10:1: note [I900N]: candidate not viable: cannot convert argument of type 'f64' to parameter 'x' of type 'i64'
// DIAG: {{.*}}:18:14: error [SC063E]: no matching overload for call to 'k_bool'
// DIAG-NEXT: {{.*}}:11:1: note [I900N]: candidate not viable: cannot convert argument of type 'f64' to parameter 'x' of type 'bool'
// DIAG: {{.*}}:19:14: error [SC063E]: no matching overload for call to 'take_ll'
// DIAG-NEXT: {{.*}}/float_narrow.h:6:1: note [I900N]: candidate not viable: cannot convert argument of type 'f64' to parameter '__arg0' of type 'i64'
// DIAG: {{.*}}:20:14: error [SC063E]: no matching overload for call to 'take_b'
// DIAG-NEXT: {{.*}}/float_narrow.h:7:1: note [I900N]: candidate not viable: cannot convert argument of type 'f64' to parameter '__arg0' of type 'bool'
// DIAG: {{.*}}:21:14: error [SC063E]: no matching overload for call to 'take_t'
// DIAG-NEXT: {{.*}}/float_narrow.h:8:1: note [I900N]: candidate not viable: cannot convert argument of type 'f64' to parameter '__arg1' of type 'i64'
// DIAG: {{.*}}:22:14: error [SC066E]: no operator '+' for operands 'Box' and 'f64'
// DIAG: {{.*}}:23:5: error [SC063E]: no matching overload for call to 'push_back'
// DIAG-NEXT: {{.*}}/vector.h:462:3: note [I900N]: candidate not viable: cannot convert argument of type 'f64' to parameter '__x' of type 'const i64&'
// DIAG-NEXT: {{.*}}/vector.h:464:3: note [I900N]: candidate not viable: cannot convert argument of type 'f64' to parameter '__x' of type 'i64&&'
// DIAG: {{.*}}:24:18: error [SC028E]: cannot convert 'f64' to 'i64'; the conversion may lose value and needs an explicit 'as'
// DIAG: {{.*}}:25:19: error [SC028E]: cannot convert 'f64' to 'bool'
// END-GENERATED-CHECKS(DIAG)
