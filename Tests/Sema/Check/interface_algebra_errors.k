// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
//
// What a composition rejects (SC001E placeholders until the sweep).
//
// `+` of one requirement with two return types:
// CHECK: interface_algebra_errors.k:35:25: error [SC001E]: 'goo' is required twice with the same parameters and different return types; one requirement cannot return both
// CHECK: note [I900N]: 'goo' returning 'i64' is declared here
// CHECK: note [I900N]: 'goo' returning 'i32' is declared here
// Trap B: Container - HasItem removes `type Item` and keeps `get`, which names it:
// CHECK: interface_algebra_errors.k:39:27: error [SC001E]: this composition removes associated type 'Item' but keeps 'get', which names 'Self::Item'; nothing would supply the type
// CHECK: note [I900N]: 'get' names it here
// Trap C: two different defaults for one associated type:
// CHECK: interface_algebra_errors.k:43:27: error [SC001E]: associated type 'K' is given two different defaults, 'i32' and 'f64'
// No requirements, written or composed (D8):
// CHECK: interface_algebra_errors.k:45:1: error [SC001E]: interface 'Empty' has no requirements; every type conforms to it, so it constrains nothing. Remove it
// CHECK: interface_algebra_errors.k:46:1: error [SC001E]: interface 'Gone' has no requirements; every type conforms to it, so it constrains nothing. Remove it
// A leaf that is not an interface:
// CHECK: interface_algebra_errors.k:48:24: error [SC001E]: 'Plain' is not an interface; a 'derives' clause composes interfaces
// A cycle:
// CHECK: interface_algebra_errors.k:50:1: error [SC001E]: interface 'P' derives from itself
// CHECK-NOT: error
//
//
//
//
//
//
//
//
//
//
//
interface D1 { fn goo(self) -> i64 }
interface D2 { fn goo(self) -> i32 }
interface DC derives D1 + D2 { }

interface Container { type Item  fn get(self, idx: usize) -> Self::Item }
interface HasItem { type Item }
interface Mystery derives Container - HasItem { }

interface DF1 { type K = i32 }
interface DF2 { type K = f64 }
interface DFU derives DF1 + DF2 { }

interface Empty { }
interface Gone derives D1 - D1 { }
struct Plain { var x: i32 }
interface NotI derives Plain + D1 { }

interface P derives Q { fn p(self) }
interface Q derives P { fn q(self) }
