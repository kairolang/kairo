// The subset rules (PANIC.md §2.2).
// - An override's set is a subset of the base method's: a caller through
//   the base handles only the base's set. Overriding a method that does
//   not panic with one that does is the same error.
// - A conforming method's set is a subset of the requirement's.
// - The set is part of a `fn` type: a function whose set is S converts to
//   a `fn` type whose set is S' only when S is a subset of S'; one that
//   does not panic converts to any panicking `fn` type. A call through a
//   `fn` value panics with its type's set.
// - A function used as a value must declare its set: the value's type
//   carries it, and an inferred set is known only after types are given.
// Each subset error's edit adds the types to the larger, declared set.

struct E { var code: i32 }
struct F { var code: i32 }

class Base {
    var n: i32
    virtual fn read(self) panic(E) -> i32 { panic E { code: 0 } }
    virtual fn quiet(self) -> i32 { return 0 }
}

class Derived derives Base {
    override fn read(self) panic -> i32 { panic F { code: 1 } }
    override fn quiet(self) panic(E) -> i32 { panic E { code: 2 } }
}

// Within the base's set: accepted.
class Fine derives Base {
    override fn read(self) panic -> i32 { panic E { code: 3 } }
}

interface Source {
    fn next(self) panic(E) -> i32
}

class Stream impl Source {
    var n: i32
    fn next(self) panic -> i32 { panic F { code: 4 } }
}

fn raises_e() panic(E) -> i32 { panic E { code: 5 } }
fn raises_ef() panic(E, F) -> i32 { panic F { code: 6 } }
fn no_panic() -> i32 { return 7 }
fn inferred() panic -> i32 { panic F { code: 8 } }

fn run(f: fn() panic(E, F) -> i32) panic(E, F) -> i32 { return f() }

fn conversions() -> i32 {
    var a: fn() panic(E, F) -> i32 = raises_e     // subset: accepted
    var b: fn() panic(E) -> i32 = no_panic        // no panic: accepted
    var c: fn() panic(E) -> i32 = raises_ef       // not a subset
    var d: fn() -> i32 = raises_e                 // a panic where none may be
    var e = inferred                              // its set is inferred
    return try run(raises_e) catch => 0
}

// A call through the value panics with its type's set.
fn through(f: fn() panic(F) -> i32) panic(E) -> i32 {
    return f()
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: subsets.k:24:28: error [SC001E]: 'F' is not in the panic set of 'Base::read', which this overrides; an override's set must be a subset of it
// CHECK-NEXT: fix-it:"{{.*}}subsets.k":{19:34-19:34}:", F"
// CHECK-NEXT: subsets.k:19:5: note [SC001N]: 'Base::read' is declared here
// CHECK: subsets.k:25:29: error [SC001E]: an override cannot panic when 'Base::quiet', which it overrides, does not: it panics with 'E'
// CHECK-NEXT: subsets.k:20:5: note [SC001N]: 'Base::quiet' is declared here
// CHECK: subsets.k:39:19: error [SC001E]: 'F' is not in the panic set of 'Source::next', which this implements; a conforming method's set must be a subset of it
// CHECK-NEXT: fix-it:"{{.*}}subsets.k":{34:26-34:26}:", F"
// CHECK-NEXT: subsets.k:34:5: note [SC001N]: 'Source::next' is declared here
// CHECK: subsets.k:52:35: error [SC028E]: cannot convert 'fn () panic(E, F) -> i32' to 'fn () panic(E) -> i32'
// CHECK: subsets.k:53:26: error [SC028E]: cannot convert 'fn () panic(E) -> i32' to 'fn () -> i32'
// CHECK: subsets.k:54:13: error [SC001E]: 'inferred' is used as a value, but its panic set is inferred: a 'fn' value's type carries the set, so 'inferred' must declare it
// CHECK-NEXT: fix-it:"{{.*}}subsets.k":{45:15-45:20}:"panic(F)"
// CHECK-NEXT: subsets.k:45:1: note [SC001N]: 'inferred' is declared here
// CHECK: subsets.k:60:12: error [SC001E]: 'F' is not in the declared panic set of 'through'
// CHECK-NEXT: fix-it:"{{.*}}subsets.k":{59:44-59:44}:", F"
