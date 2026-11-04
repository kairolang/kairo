// RUN: { %kairo %s --type-check-only --error-format=basic 2>&1 || true; } | %FileCheck %s --allow-empty
//
// `Ded(self.dyn()->sc, &null)` inside a generic class: the first argument is
// instantiation-dependent, so the constructor is undecided and the bare
// `&null` has no parameter to take its pointer type from. It stays untyped
// (it goes out as `nullptr`, converting to whichever pointer the instance's
// constructor takes), as `_type_args_dependent` does for a member call,
// instead of SC076E "cannot infer the pointer type of '&null'" (G99 d,
// MemberTyping.k).

class Ctx { pub var x: i32 = 0 }
class Cv { pub var y: i32 = 0 }
class Ded {
    pub var sc: unsafe *Ctx
    pub var conv: unsafe *Cv
    fn Ded(self, sc: unsafe *Ctx, conv: unsafe *Cv) { self.sc = sc; self.conv = conv }
    fn Ded(self) { self.sc = &null; self.conv = &null }
}
class <T: type> MT {
    priv inline fn dyn(self) -> unsafe *T { return unsafe ((unsafe &self) as unsafe *T); }
    fn go(self, o: unsafe *Ctx) {
        if o != &null {
            var sd = Ded(self.dyn()->sc, &null)
        }
    }
}
class Host { pub var sc: unsafe *Ctx }
fn main() { var m: MT<Host>; m.go(&null) }

// CHECK-NOT: SC076E
// CHECK-NOT: error
