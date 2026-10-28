// BaseInitCheck: a constructor is called by name only to initialize a base,
// as one of the first statements of a derived class's constructor, with
// `self` first and nowhere else; each base once; and a base with no default
// constructor is initialized by every constructor of a class deriving it
// (an implicit one cannot). Left to clang, each of these was CL001E in the
// generated C++ ("must explicitly initialize the base class", ...).

class Animal {
    pub var legs: i32
    fn Animal(self, legs: i32) { self.legs = legs }
}

class Dog derives Animal {
    var good: i32
    fn Dog(self) { self.good = 1 }
}

class Cat derives Animal {
}

class Bird derives Animal {
    fn Bird(self) {
        self.legs = 2
        Animal::Animal(self, 2)
    }
}

class Fish derives Animal {
    var fins: i32
    fn Fish(self) {
        Animal::Animal(self, self.fins)
    }
}

class Ant derives Animal {
    fn Ant(self) {
        Animal::Animal(self, 6)
        Animal::Animal(self, 6)
    }
}

class Other {
    fn Other(self) { }
}

class Snake derives Animal {
    fn Snake(self, o: Other) {
        Animal::Animal(self, 0)
        Other::Other(o)
    }
}

class Mole derives Animal {
    fn Mole(self, a: Animal) {
        Animal::Animal(a, 4)
    }
}

class NoDefault {
    fn NoDefault(self) = delete
}

class Kid derives NoDefault {
}

class OnlyCopy {
    @copy
    fn OnlyCopy(self, const other: Self) = delete
}

class Heir derives OnlyCopy {
    fn Heir(self) { }
}

class Self1 {
    fn Self1(self, n: i32) { }
    fn Self1(self) { Self1::Self1(self, 1) }
}

fn free() {
    var a = Animal(4)
    Animal::Animal(a, 3)
}

// Adjacent and unchanged: a base with a default constructor needs no call,
// and constructing a value by the type's name is not a base initializer.
class Plain { pub var p: i32 = 1 }
class PlainKid derives Plain { fn PlainKid(self) { } }
fn build() -> i32 { var a = Animal(4); return a.legs }

// A base that declares no constructor has the implicit one only when that
// can build it (TypeUtil::why_no_default): an uninitialized `bool` cannot.
class Flag { var on: bool }
class FlagKid derives Flag { fn FlagKid(self) { } }

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:15:8: error [SC001E]: constructor of 'Dog' does not initialize its base 'Animal', and 'Animal' has no default constructor
// DIAG-NEXT: {{.*}}:13:19: note [SC001N]: 'Animal' is a base here; call one of its constructors first in the body: 'Animal::Animal(self, ...)'
// DIAG: {{.*}}:18:7: error [SC001E]: 'Cat' has no constructor, so nothing initializes its base 'Animal', and 'Animal' has no default constructor
// DIAG-NEXT: {{.*}}:18:19: note [SC001N]: 'Animal' is a base here; declare a constructor whose first statement calls one of its own: 'Animal::Animal(self, ...)'
// DIAG: {{.*}}:22:8: error [SC001E]: constructor of 'Bird' does not initialize its base 'Animal', and 'Animal' has no default constructor
// DIAG-NEXT: {{.*}}:21:20: note [SC001N]: 'Animal' is a base here; call one of its constructors first in the body: 'Animal::Animal(self, ...)'
// DIAG: {{.*}}:24:9: error [SC001E]: a constructor is called by name only to initialize a base, as one of the first statements of a constructor of a derived class
// DIAG-NEXT: {{.*}}:10:8: note [SC001N]: to build an object of 'Animal', call the type by name instead
// DIAG: {{.*}}:31:30: error [SC001E]: 'self' cannot be used in the arguments of the initializer of base 'Animal': the object is built only after its bases
// DIAG-NEXT: {{.*}}:31:9: note [SC001N]: base initializers run before any field is initialized
// DIAG: {{.*}}:38:9: error [SC001E]: base 'Animal' is initialized twice
// DIAG-NEXT: fix-it:"{{.*}}":{38:9-38:32}:""
// DIAG: {{.*}}:49:9: error [SC001E]: 'Other' is not a direct or virtual base of 'Snake'; a constructor initializes only those
// DIAG-NEXT: {{.*}}:42:7: note [SC001N]: 'Other' is declared here
// DIAG: {{.*}}:55:24: error [SC001E]: a base initializer builds the base part of 'self'; its first argument must be 'self'
// DIAG-NEXT: fix-it:"{{.*}}":{55:24-55:25}:"self"
// DIAG-NEXT: {{.*}}:55:9: note [SC001N]: this initializes base 'Animal'
// DIAG: {{.*}}:63:7: error [SC001E]: 'Kid' has no constructor, so nothing initializes its base 'NoDefault', and the default constructor of 'NoDefault' is deleted
// DIAG-NEXT: {{.*}}:63:19: note [SC001N]: 'NoDefault' is a base here; declare a constructor whose first statement calls one of its own: 'NoDefault::NoDefault(self, ...)'
// DIAG: {{.*}}:72:8: error [SC001E]: constructor of 'Heir' does not initialize its base 'OnlyCopy', and 'OnlyCopy' has no default constructor: declaring its transfer constructor removed the implicit one (declare 'fn OnlyCopy(self) = default' to keep it)
// DIAG-NEXT: {{.*}}:71:20: note [SC001N]: 'OnlyCopy' is a base here; call one of its constructors first in the body: 'OnlyCopy::OnlyCopy(self, ...)'
// DIAG: {{.*}}:77:22: error [SC001E]: a constructor of 'Self1' cannot call another of its own constructors; only a base constructor is called by name
// DIAG-NEXT: {{.*}}:77:8: note [SC001N]: this constructor builds the object itself
// DIAG: {{.*}}:82:5: error [SC001E]: a constructor is called by name only to initialize a base, as one of the first statements of a constructor of a derived class
// DIAG-NEXT: {{.*}}:10:8: note [SC001N]: to build an object of 'Animal', call the type by name instead
// DIAG: {{.*}}:94:33: error [SC001E]: constructor of 'FlagKid' does not initialize its base 'Flag', and 'Flag' has no default constructor: the implicit one cannot build field 'on', which has no initializer ('bool' has no zero state: a default would have to guess true or false)
// DIAG-NEXT: {{.*}}:94:23: note [SC001N]: 'Flag' is a base here and declares no constructor to call; give it one, or make its implicit one possible
// END-GENERATED-CHECKS(DIAG)
