// `&null` as an argument of a member call through a `: type` parameter
// (`self.dyn()->host.type_of(e, &null)`, the self-host mixins' shape) has
// no parameter to take a pointer type from: only the instance resolves the
// call. It goes out as `nullptr`, which converts to whatever pointer the
// parameter clang picks takes. It used to be SC076E "cannot infer the
// pointer type of '&null' here".

class Ty { pub var a: i32 = 0 }
class Host {
    fn type_of(self, e: unsafe *Ty, exp: unsafe *Ty) -> i32 {
        if exp == &null { return 1 }
        return 2
    }
}
class <X: type> Mixin {
    priv inline fn dyn(self) -> unsafe *X { return unsafe ((unsafe &self) as unsafe *X) }
    fn f(self, e: unsafe *Ty) -> i32 { return self.dyn()->host.type_of(e, &null) }
}
class S derives Mixin<S> { pub var host: Host }

fn main() -> i32 {
    var s = S()
    return s.f(&null) + 6
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo -fduck-generics %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error [

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo -fduck-generics %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 7
