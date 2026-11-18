// A member type of an imported class template named without the template's
// arguments (`traits::size_type`) names nothing in C++: it is the arity
// error a bare `traits` is, in a generic and outside one.

ffi "c++" import "traits_typedef.h"

fn plain(x: traits::size_type) -> u64 { return 0 }
fn <T> gen(x: traits<T>::size_type) -> traits::size_type { return x }

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s -I %S --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: dep_path_template_no_args.k:7:13: error [R032E]: 'traits' requires at least 1 generic argument(s), but 0 were given
// CHECK: dep_path_template_no_args.k:8:40: error [R032E]: 'traits' requires at least 1 generic argument(s), but 0 were given
// CHECK-NOT: {{error|Internal Compiler Error}}
