// Kairo has no uninitialized variable: `var x: T` default-constructs T,
// so T must have a default. A number or a pointer is zero (null); a
// record needs a constructor callable on `self` alone, or none (the
// implicit one; implicit_default_ctor_*.k); `bool` has no
// zero state to assume. An array follows its element. A brace
// initializer builds an aggregate field by field, which a class that
// declares a constructor is not (SC088E). Loop and pattern binders are
// bound, not default-built, and are never checked.

class Empty { }
class Def { fn Def(self) = default }
class Body { pub var a: i32
    fn Body(self) { self.a = 1 } }
class Del { fn Del(self) = delete }
class Arg { pub var a: i32
    fn Arg(self, a: i32) { self.a = a } }
class Opt { pub var a: i32
    fn Opt(self, a: i32 = 4) { self.a = a } }
class Two { pub var a: i32
    fn Two(self, a: i32) { self.a = a }
    fn Two(self) { self.a = 0 } }
struct Pod { pub var a: i32 }
class Agg { pub var a: i32 }
class <T> Box { pub var v: T
    fn Box(self) = default }
class <T> Bare { pub var v: T }

var g_empty: Empty             // ok: the implicit constructor
var g_int: i64

fn locals() {
    var a: Empty                // ok: the implicit constructor
    var b: Def                  // ok
    var c: Body                 // ok
    var d: Del
    var e: Arg
    var f: Opt                  // SC116E: legal, not compiled yet
    var h: Two                  // ok: one of its overloads is nullary
    var i: bool
    var j: i32                  // ok: 0
    var k: f64                  // ok: 0
    var l: *i32                 // ok: null
    var m: [bool; 2]
    var n: [Def; 2]             // ok
    var o: [Arg; 2]
    var p: Pod                  // ok: the implicit constructor
    var q: Box<i32>             // ok
    var r: Bare<i32>            // ok: the implicit constructor
    var s: string               // ok: the builtin string has a default
    for x in [1, 2] { }         // ok: a binder, not a declaration
}

fn braces() {
    var a = Def{}
    var b = Arg{a: 1}
    var c = Agg{a: 1}           // ok: an aggregate
    var d = Pod{a: 1}           // ok
    var e = Def()               // ok: the constructor
    var f: Arg = Arg(2)         // ok
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK-NOT: error
// CHECK: default_init.k:35:5: error [SC001E]: 'd' {{.*}} the default constructor of 'Del' is deleted
// CHECK: default_init.k:36:5: error [SC001E]: 'e' {{.*}} 'Arg' has no default constructor
// CHECK: default_init.k:37:5: error [SC116E]: 'f' would be built by a constructor whose arguments all default
// CHECK: default_init.k:39:5: error [SC001E]: 'i' {{.*}} 'bool' has no zero state
// CHECK: default_init.k:43:5: error [SC001E]: 'm' {{.*}} 'bool' has no zero state
// CHECK: default_init.k:45:5: error [SC001E]: 'o' {{.*}} 'Arg' has no default constructor
// CHECK: default_init.k:54:13: error [SC088E]: 'Def' declares a constructor, so it cannot be built with a brace initializer
// CHECK: default_init.k:55:13: error [SC088E]: 'Arg' declares a constructor
// CHECK-NOT: error
