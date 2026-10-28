// A derived constructor initializes its base by calling the base's
// constructor by qualified name, `Base::Base(self, args)`
// (classes-inheritance.md, Inheritance; the diamond example's `A::A`).
//
// Formerly an expected failure: `Animal::Animal(self, ...)` was R025E "no
// member named 'Animal' in 'Animal'", so a base with only a parameterized
// constructor could not be derived at all (Kairo accepted the class, clang
// rejected it with "must explicitly initialize the base class"). The name
// now finds the constructors (ChainBinding), the leading calls become the
// C++ mem-initializers (EmitIR), and BaseInitCheck refuses the rest;
// base_ctor_shapes.k, base_ctor_transfer.k, base_ctor_cross_module.k and
// Sema/Check/base_init_errors.k cover the rest.

class Animal {
    prot var legs: i32
    fn Animal(self, legs: i32) { self.legs = legs }
    fn legs_of(self) -> i32 { return self.legs }
}

class Dog derives Animal {
    var good: i32
    fn Dog(self, good: i32) {
        Animal::Animal(self, 4)
        self.good = good
    }
    fn score(self) -> i32 { return self.legs * 10 + self.good }
}

fn main() -> i32 {
    var d = Dog(2)
    return d.score() + d.legs_of()              // 42 + 4
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 46
