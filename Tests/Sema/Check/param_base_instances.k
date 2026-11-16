// `class <A derives Base> Hooked derives A` derives its argument, so each
// `Hooked<X>` needs X to be a class a class may derive, and says so where
// the instance is used (SC352E), with a note at the base clause: X is not
// `final`, has a default constructor, since the base is always built by it,
// and declares no field or same-signature method in place of a non-virtual
// one of the bound, which the mixin's body was bound to (an `override` of a
// virtual and a new overload are fine; a static counts as a method). An
// argument with a virtual destructor needs its bound to have one, or an
// object destroyed through the argument's type would be measured without
// the mixin. A class deriving `Hooked<Loop>` as
// `Loop` is not complete where its base needs it (SC002E), and an argument
// that does not derive the bound, a primitive included, is the bound's own
// error (SC156E). `Hooked<Base>`, `Hooked<Mid>` and two stacked are clean.

class Base {
    pub var n: i32 = 3
    pub fn Base(self) { }
    pub virtual fn begin(self) -> i32 { return 1 }
    pub fn plain(self) -> i32 { return self.n }
    pub static fn make() -> i32 { return 40 }
}

class Mid derives Base {
    pub fn Mid(self) { }
}

final class Sealed derives Base {
    pub fn Sealed(self) { }
}

class NeedsArg derives Base {
    pub fn NeedsArg(self, k: i32) { self.n = k }
}

class Unrelated {
    pub fn Unrelated(self) { }
}

class HidesField derives Base {
    pub var n: f64 = 2.5
    pub fn HidesField(self) { }
}

class HidesMethod derives Mid {
    pub fn HidesMethod(self) { }
    pub fn plain(self) -> f64 { return 9.5 }
}

class HidesStatic derives Base {
    pub fn HidesStatic(self) { }
    pub static fn make() -> f64 { return 0.5 }
}

class Plain {
    pub var k: i32 = 0
    pub fn Plain(self) { }
}

class VirtualEnd derives Plain {
    pub fn VirtualEnd(self) { }
    pub virtual fn op finally(self) { }
}

class <A derives Plain> Thin derives A {
    pub var t: i32 = 0
}

class Overloads derives Base {
    pub fn Overloads(self) { }
    pub fn plain(self, k: f64) -> f64 { return k }
    pub override fn begin(self) -> i32 { return 2 }
}

class <A derives Base> Hooked derives A {
    pub override fn begin(self) -> i32 { return A::begin(self) + 100 }
}

class Loop derives Hooked<Loop> {
    pub fn Loop(self) { }
}

fn clean() -> i32 {
    var a = Hooked<Base>()
    var b = Hooked<Mid>()
    var c = Hooked<Hooked<Mid>>()
    var d = Hooked<Overloads>()
    return a.begin() + b.begin() + c.begin() + d.begin()
}

fn hides() -> i32 {
    var f = Hooked<HidesField>()
    var m = Hooked<HidesMethod>()
    var s = Hooked<HidesStatic>()
    return f.begin() + m.begin() + s.begin()
}

fn virtual_end() -> i32 {
    var ok = Thin<Plain>()
    var t = Thin<VirtualEnd>()
    return ok.t + t.t
}

fn sealed() -> i32 {
    var s = Hooked<Sealed>()
    return s.begin()
}

fn needs_arg() -> i32 {
    var s = Hooked<NeedsArg>()
    return s.begin()
}

fn unrelated() -> i32 {
    var s = Hooked<Unrelated>()
    return 0
}

fn primitive(p: *Hooked<i32>) -> i32 { return 0 }

fn main() -> i32 {
    return clean()
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: {{.*}}param_base_instances.k:61:9: warning [SC060W]: 'VirtualEnd' has a custom destructor but no '@copy' or '@move' transfer constructor; it is implicitly copyable
// CHECK-NEXT: {{.*}}param_base_instances.k:61:9: note [I900N]: declare it move-only: '@move fn VirtualEnd(self, other: Self) = default'
// CHECK-NEXT: {{.*}}param_base_instances.k:61:9: note [I900N]: or make it non-transferable: '@copy fn VirtualEnd(self, const other: Self) = delete'
// CHECK: {{.*}}param_base_instances.k:78:1: error [SC002E]: 'Loop' contains itself by value; its layout would have to include its own size
// CHECK-NEXT: {{.*}}param_base_instances.k:78:20: note [I900N]: 'Loop' holds 'Loop' by value, closing the cycle
// CHECK: {{.*}}param_base_instances.k:78:20: error [SC156E]: 'Loop' does not derive 'Base'
// CHECK-NEXT: {{.*}}param_base_instances.k:74:8: note [I900N]: required by this bound
// CHECK: {{.*}}param_base_instances.k:91:13: error [SC352E]: 'Hooked<HidesField>' cannot derive 'HidesField': 'HidesField' declares a field 'n' that hides the one of 'Base', and 'Hooked' is checked against 'Base'
// CHECK-NEXT: {{.*}}param_base_instances.k:74:39: note [SC352N]: 'Hooked' derives its type parameter here
// CHECK: {{.*}}param_base_instances.k:92:13: error [SC352E]: 'Hooked<HidesMethod>' cannot derive 'HidesMethod': 'HidesMethod' declares a method 'plain' with the parameters of the non-virtual one of 'Base', which it hides, and 'Hooked' is checked against 'Base'
// CHECK-NEXT: {{.*}}param_base_instances.k:74:39: note [SC352N]: 'Hooked' derives its type parameter here
// CHECK: {{.*}}param_base_instances.k:93:13: error [SC352E]: 'Hooked<HidesStatic>' cannot derive 'HidesStatic': 'HidesStatic' declares a method 'make' with the parameters of the non-virtual one of 'Base', which it hides, and 'Hooked' is checked against 'Base'
// CHECK-NEXT: {{.*}}param_base_instances.k:74:39: note [SC352N]: 'Hooked' derives its type parameter here
// CHECK: {{.*}}param_base_instances.k:99:13: error [SC352E]: 'Thin<VirtualEnd>' cannot derive 'VirtualEnd': 'VirtualEnd' has a virtual destructor and 'Plain', the bound 'Thin' is checked against, has none; declare 'virtual fn op finally(self)' in 'Plain'
// CHECK-NEXT: {{.*}}param_base_instances.k:64:38: note [SC352N]: 'Thin' derives its type parameter here
// CHECK: {{.*}}param_base_instances.k:104:13: error [SC352E]: 'Hooked<Sealed>' cannot derive 'Sealed': 'Sealed' is final
// CHECK-NEXT: {{.*}}param_base_instances.k:74:39: note [SC352N]: 'Hooked' derives its type parameter here
// CHECK: {{.*}}param_base_instances.k:109:13: error [SC352E]: 'Hooked<NeedsArg>' cannot derive 'NeedsArg': the base of 'Hooked<NeedsArg>' is built by its default constructor, and 'NeedsArg' has no default constructor (declare 'fn NeedsArg(self)')
// CHECK-NEXT: {{.*}}param_base_instances.k:74:39: note [SC352N]: 'Hooked' derives its type parameter here
// CHECK: {{.*}}param_base_instances.k:114:13: error [SC156E]: 'Unrelated' does not derive 'Base'
// CHECK-NEXT: {{.*}}param_base_instances.k:74:8: note [I900N]: required by this bound
// CHECK: {{.*}}param_base_instances.k:118:17: error [SC156E]: 'i32' does not derive 'Base'
// CHECK-NEXT: {{.*}}param_base_instances.k:74:8: note [I900N]: required by this bound
