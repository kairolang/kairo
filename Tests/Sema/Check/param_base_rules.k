// What a class deriving its own type parameter may be
// (classes-inheritance.mdx, Deriving a type parameter). Its body is checked
// once against the parameter's `derives` bound, so the parameter needs
// exactly one bound that names a class: with none, or with an interface
// bound only, there is nothing the body could assume of its base (SC351E,
// with a note at the parameter). A pack, a `: type` parameter, a parameter
// of an enclosing declaration, a `virtual` edge, a second parameter base
// and a class that writes its own `@copy` or `@move` constructor are each
// refused by name. `Good` is the accepted form.

class Base {
    pub var n: i32 = 3
    pub fn Base(self) { }
    pub fn Base(self, k: i32) { self.n = k }
    pub virtual fn begin(self) -> i32 { return 1 }
}

class Wide derives Base {
    pub fn Wide(self) { }
    pub fn only_wide(self) -> i32 { return 2 }
}

interface Named { fn name(self) -> i32 }

class <A> NoBound derives A { }

class <A impl Named> IfaceBound derives A { }

class <...A> Pack derives A { }

class <A: type> Duck derives A { }

class <A derives Base> Virt derives virtual A { }

class <A derives Base, B derives Base> Two derives A, B { }

class <A derives Base> Outer {
    class Inner derives A { }
}

class <A derives Base> Copies derives A {
    pub var k: i32 = 0
    pub fn Copies(self) { }
    @copy
    pub fn Copies(self, const other: Self) { self.k = other.k }
}

class <A derives Base> Good derives A {
    pub fn fine(self) -> i32 { return self.n + self.begin() + A::begin(self) + Base::begin(self) }
}

fn main() -> i32 {
    var g = Good<Wide>()
    return g.fine() + g.only_wide()
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: {{.*}}param_base_rules.k:25:27: error [SC351E]: 'NoBound' cannot derive its type parameter 'A': 'A' has no 'derives' bound that names a class, so the body of 'NoBound' could assume nothing of its base; write '<A derives SomeBase>'
// CHECK-NEXT: {{.*}}param_base_rules.k:25:8: note [SC351N]: 'A' is declared here
// CHECK: {{.*}}param_base_rules.k:27:41: error [SC351E]: 'IfaceBound' cannot derive its type parameter 'A': 'A' has no 'derives' bound that names a class, so the body of 'IfaceBound' could assume nothing of its base; write '<A derives SomeBase>'
// CHECK-NEXT: {{.*}}param_base_rules.k:27:8: note [SC351N]: 'A' is declared here
// CHECK: {{.*}}param_base_rules.k:29:27: error [SC351E]: 'Pack' cannot derive its type parameter 'A': 'A' is a parameter pack; a base is one class (not supported yet)
// CHECK-NEXT: {{.*}}param_base_rules.k:29:8: note [SC351N]: 'A' is declared here
// CHECK: {{.*}}param_base_rules.k:31:9: error [SC198E]: 'A: type' needs -fduck-generics: a generic body is checked against its bounds, not per instance
// CHECK-NEXT: fix-it:"{{.*}}param_base_rules.k":{31:9-31:15}:""
// CHECK-NEXT: note [I900N]: `: type` is the transitional regime clang checks per instance; -fduck-generics enables it
// CHECK: {{.*}}param_base_rules.k:31:30: error [SC351E]: 'Duck' cannot derive its type parameter 'A': 'A' is declared ': type', so nothing is known of the base; give it a class bound: 'A derives SomeBase'
// CHECK-NEXT: {{.*}}param_base_rules.k:31:8: note [SC351N]: 'A' is declared here
// CHECK: {{.*}}param_base_rules.k:33:37: error [SC351E]: 'Virt' cannot derive its type parameter 'A': a 'virtual' base that is a type parameter is not supported yet
// CHECK-NEXT: {{.*}}param_base_rules.k:33:8: note [SC351N]: 'A' is declared here
// CHECK: {{.*}}param_base_rules.k:35:55: error [SC351E]: 'Two' cannot derive its type parameter 'B': 'Two' already derives another of its type parameters; more than one type-parameter base is not supported yet
// CHECK-NEXT: {{.*}}param_base_rules.k:35:24: note [SC351N]: 'B' is declared here
// CHECK: {{.*}}param_base_rules.k:38:25: error [SC351E]: 'Inner' cannot derive its type parameter 'A': 'A' is a type parameter of an enclosing declaration, not of 'Inner'; a class derives only its own type parameter (not supported yet)
// CHECK-NEXT: {{.*}}param_base_rules.k:37:8: note [SC351N]: 'A' is declared here
// CHECK: {{.*}}param_base_rules.k:41:39: error [SC351E]: 'Copies' cannot derive its type parameter 'A': 'Copies' writes its own '@copy' or '@move' constructor, which would have to transfer the base through a constructor the bound of 'A' does not promise; declare it '= default' or leave it out (not supported yet)
// CHECK-NEXT: {{.*}}param_base_rules.k:41:8: note [SC351N]: 'A' is declared here
