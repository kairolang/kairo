// A script variable of array type whose initializer is not constant
// would be deferred to `Nullable<[T; N]>` storage, which the library
// cannot build: SC235E (a script feature not supported yet), as for a
// nullable one, instead of clang's "cannot initialize an array element".
// A list literal of constants is not deferred.

fn f() -> i32 { return 2 }

var ok: [i32; 2] = [1, 2]
var bad: [i32; 2] = [1, f()]
ok[0] = bad[1]

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: script_array_deferred.k:10:1: error [SC235E]: a script variable of array type with an initializer that is not constant is not supported yet
// CHECK: script_array_deferred.k:10:1: note [SC235N]: initialize it from a list literal of constants, and assign the elements on the next lines
