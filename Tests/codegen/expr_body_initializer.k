// An expression body that is an initializer reaches codegen typed. A written return type
// does not keep the body from being visited, so EmitIR::_init meets no
// "untyped initializer reached
// codegen".
// Free functions, extension members (static and instance) and class methods
// all go through the same path.

struct R { var a: u32 }

fn f(x: u32) -> R = R { a: x }

extend R {
    static fn make(x: u32) -> R = R { a: x }
    fn get(const self) -> u32 = self.a
}

class C {
    var v: u32
    fn C(self) { self.v = 1 }
    fn twice(const self) -> u32 = self.v * 2
}

fn use_all() -> u32 {
    var r = R::make(3)
    return f(1).a + r.get() + C().twice()
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error
//
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -c --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=OBJ --allow-empty
// OBJ-NOT: I011W
// OBJ-NOT: Internal Compiler Error
// RUN: find %t.d -name '*.o' | grep . >/dev/null
