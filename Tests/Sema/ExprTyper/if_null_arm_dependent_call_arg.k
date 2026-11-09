// An `if` expression whose first arm is instantiation-dependent and whose
// other arm is a bare `&null`, passed as a call argument. No type is
// expected while the arguments are typed, and the first arm lends none yet:
// the `&null` goes out as `nullptr` and converts to the parameter's pointer
// in the instance, as a bare `&null` argument to a dependent call does.
// A `&null` arm with nothing dependent beside it stays an error.

class Ty { var x: i32 }

class <S: type> PT {
    priv inline fn dyn(self) -> unsafe *S { return unsafe ((unsafe &self) as unsafe *S); }
    fn f(self, t: unsafe *Ty) {}
    fn g(self, have: bool) {
        var elems = self.dyn()->lst()
        self.f(if (have) => (elems[0]) else => &null)
        self.f(if have => elems[0] else if have => &null else => &null)
        var d = if have => elems[0] else => &null
    }
}

fn bare(have: bool) {
    var q = if have => &null else => &null
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not=SC076E

// CHECK: if_null_arm_dependent_call_arg.k:22:24: error [SC076E]
// CHECK: if_null_arm_dependent_call_arg.k:22:38: error [SC076E]
