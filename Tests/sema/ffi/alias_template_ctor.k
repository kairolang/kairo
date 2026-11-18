// A generic alias APPLIED as a constructor call (`BoxA<unsafe *i32>(...)`,
// a C++ alias template or a Kairo `type <T>` alias) constructs the alias's
// body at the arguments, as the same alias in a type position does. The
// expression path returned the bare body, the PATTERN (`Box<T>`): the call
// typed as a dependent `Box<T>` in non-generic code, its constructor went
// unselected, and a `&null` argument had no pointer type (SC076E, the
// self-host's `kairo::std::Atomic<unsafe *X>(&null)`).

ffi "c++" import "alias_template_ctor.h"

class <T> KB { pub var v: T; fn KB(self, v: T) { self.v = v; } }
type <T> KA = KB<T>;

fn f() {
    var x: i32 = 1
    var a = BoxA<unsafe *i32>(&null)
    var b = At<unsafe *i32>(&null)
    var c = KA<i32>(x)
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --print-sema 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: SEMA fid {{[0-9]+}}: {{.*}}alias_template_ctor.k =====
// CHECK: -- inferred decls --
// CHECK-DAG: a : Box<unsafe *i32>
// CHECK-DAG: c : KB<i32>
