// `fn ::gf(...)` for a C++ global `int gf(int)`. The parser took
// `fn ::` for a closure, skipped `::gf(a: i32)` without a word, and the body
// reported R020E "use of undeclared identifier 'a'". Whether `fn ::name`
// should define the C++ global is not specified, so it is
// one error at the name, S093E, and the function is checked on as a Kairo
// `fn gf`: its parameters resolve and nothing cascades. A qualified name
// with a leading `::` gets S093E with a fix-it removing the `::`;
// `fn ns::nf` is unchanged.

ffi "c++" import "g.h"

fn ::gf(a: i32) -> i32 { return a + 1 }
fn ::ns::nf(a: i32) -> i32 { return a }

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo -I %S/Inputs/define_cxx_global %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: define_cxx_global_rooted.k:12:4: error [S093E]: 'fn ::gf' would define the C++ global function 'gf'; a C++ global function cannot be defined from Kairo yet
// CHECK: define_cxx_global_rooted.k:13:4: error [S093E]: a function name cannot start with '::'; a function C++ declares in a namespace or a class is defined with its qualified name alone
// CHECK-NEXT: fix-it:"{{.*}}define_cxx_global_rooted.k":{13:4-13:6}:""
