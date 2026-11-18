// Inheritance visibility on a base that is a type parameter
// (classes-inheritance.mdx): `class <A derives Base> Shut derives priv A`
// makes the members of its base private to Shut's file, whichever argument
// the base is. Through a `Shut<More>` from another module the bound's field
// and method, a method only the argument `More` declares, and a static
// named through the class are all SC242E, each with a note at the base
// clause; through a `prot` edge they are open to a class deriving the
// mixin. The conversion to `*More` and `*Base` stays available, and through
// those pointers the members have their own visibility again. `Open`
// derives its parameter plainly and narrows nothing.

import inputs::param_base_access_lib::*

fn shut() -> i32 {
    var s = Shut<More>()
    var a = s.x
    var b = s.f()
    var c = s.extra()
    var d = Shut<More>::make()
    return a + b + c + d
}

fn half() -> i32 {
    var h = Half<Base>()
    return h.x
}

class Sub derives Half<More> {
    fn Sub(self) { }
    fn reach(self) -> i32 { return self.x + self.extra() }
}

fn clean() -> i32 {
    var s = Shut<More>()
    var m: *More = &s
    var b: *Base = &s
    var o = Open<More>()
    return m->extra() + b->x + b->f() + o.x + o.f() + o.extra() + s.inside() + lib_reads(&s) + Open<More>::make()
}

fn main() -> i32 {
    return clean()
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: {{.*}}param_base_access.k:16:14: error [SC242E]: 'x' is inaccessible through 'Shut': 'Shut' derives 'Base' as private
// CHECK-NEXT: {{.*}}inputs/param_base_access_lib.k:15:41: note [SC242N]: 'Shut' declares its base 'Base' 'priv' here, so the members of 'Base' are private to 'Shut' and its file
// CHECK: {{.*}}param_base_access.k:17:14: error [SC242E]: 'f' is inaccessible through 'Shut': 'Shut' derives 'Base' as private
// CHECK-NEXT: {{.*}}inputs/param_base_access_lib.k:15:41: note [SC242N]: 'Shut' declares its base 'Base' 'priv' here, so the members of 'Base' are private to 'Shut' and its file
// CHECK: {{.*}}param_base_access.k:18:14: error [SC242E]: 'extra' is inaccessible through 'Shut': 'Shut' derives 'More' as private
// CHECK-NEXT: {{.*}}inputs/param_base_access_lib.k:15:41: note [SC242N]: 'Shut' declares its base 'More' 'priv' here, so the members of 'More' are private to 'Shut' and its file
// CHECK: {{.*}}param_base_access.k:19:23: error [SC242E]: 'make' is inaccessible through 'Shut': 'Shut' derives 'Base' as private
// CHECK-NEXT: {{.*}}inputs/param_base_access_lib.k:15:41: note [SC242N]: 'Shut' declares its base 'Base' 'priv' here, so the members of 'Base' are private to 'Shut' and its file
// CHECK: {{.*}}param_base_access.k:25:13: error [SC242E]: 'x' is inaccessible through 'Half': 'Half' derives 'Base' as protected
// CHECK-NEXT: {{.*}}inputs/param_base_access_lib.k:19:41: note [SC242N]: 'Half' declares its base 'Base' 'prot' here, so the members of 'Base' are protected to 'Half' and its file
