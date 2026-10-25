// A derived constructor initializes its base by calling the base's
// constructor by qualified name, `Base::Base(self, args)`
// (classes-inheritance.md, Inheritance; the diamond example's `A::A`).
//
// XFAIL: *
// Waiting on base-constructor calls: `Animal::Animal(self, ...)` is R025E
// "no member named 'Animal' in 'Animal'" -- the constructor is not found
// as a member by its own name. Without it a base with only a parameterized
// constructor cannot be derived at all: Kairo accepts the class and clang
// rejects it with "must explicitly initialize the base class".
// When it lands this test XPASSes; delete the XFAIL -- the run below is
// already the real assertion.

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
