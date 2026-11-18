// `as` between unrelated C++ record types is not an identity cast: it is an
// error at the cast, not an internal error in codegen, and the identity cast
// of the same type stays a warning.

ffi "c++" import "cxx_identity_cast_run.h"

fn main() -> i32 {
    var s = IdS()
    var b = IdBag(4)
    var x = s as IdBag
    var y = b as i32
    var z = s as IdS
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="I003E" --implicit-check-not="internal"
// CHECK: cxx_identity_cast_reject.k:10:13: error [SC063E]: no matching overload for call to 'IdBag'
// CHECK: cxx_identity_cast_reject.k:11:13: error [SC027E]: no conversion from 'IdBag' to 'i32'
// CHECK: cxx_identity_cast_reject.k:12:13: warning [SC031W]: redundant cast: 'IdS' converts to 'IdS' implicitly
