// A generic method's parameter that no argument mentions must be written:
// `c.m()` has no way to infer T, and more generic arguments than the method
// declares are an error. The written forms stay accepted.

class C {
    fn <T> m(self) -> i32 { return sizeof T as i32 }
}

fn main() -> i32 {
    var c = C()
    var ok = c.m<i64>()
    var a = c.m()
    var b = c.m<i64, i32>()
    return ok
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not='error ['
// CHECK: method_explicit_args_reject.k:12:13: error [SC063E]: no matching overload for call to 'm'
// CHECK: note [I900N]: candidate not viable: could not deduce every generic parameter from the arguments
// CHECK: method_explicit_args_reject.k:13:13: error [SC063E]: no matching overload for call to 'm'
// CHECK: note [I900N]: candidate not viable: it takes 1 generic argument(s), and 2 were written
