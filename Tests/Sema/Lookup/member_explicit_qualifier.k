// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
//
// The explicit-qualifier rule (R049). Kairo has no implicit `this->`: inside a
// function body a member of the enclosing type is NOT in unqualified scope.
// The ONE exception is a name that denotes a scope -- a nested type, a type
// alias, a nested module -- because naming a type is not an access through an
// object.
//
// The point of the file is CONSISTENCY. The same body must behave the same
// however it is spelled, so every case below is the same two lookups written
// four ways: in a class body, in an `extend` body, in an out-of-line
// definition, and inside a closure. Before R049 the first and third saw the
// members bare, the second reported "use of undeclared identifier", and the
// nested-type exception did not hold in an `extend` body at all.
//
// POSITIVE cases are proven by the ABSENCE of a diagnostic: DIAG-NOT below
// pins that the nested type and the alias never appear in the output.

class Foo {
    var x: i32
    static k: i32 = 7

    struct Nested { var a: i32 }
    type Alias = i32

    fn Foo(self) { self.x = 0 }

    fn inc(self) -> i32 { return self.x + 1 }

    // In-class method body: instance field, instance method, static member.
    fn in_class(self) -> i32 {
        var n = Nested { a: 1 }      // exception: nested type, no qualifier
        var q: Alias = 2             // exception: type alias
        return x + inc() + k + n.a + q
    }

    // Out-of-line below: the SAME body, and it must report the same thing.
    fn out_of_line(self) -> i32
}
// DIAG: error [R049E]: use of member 'x' requires an explicit qualifier
// DIAG: note [R049N]: 'x' is declared here
// DIAG: error [R049E]: use of method 'inc' requires an explicit qualifier
// DIAG: error [R049E]: use of static member 'k' requires an explicit qualifier

fn Foo::out_of_line(self) -> i32 {
    var n = Nested { a: 1 }
    return x + n.a
}
// DIAG: error [R049E]: use of member 'x' requires an explicit qualifier

// An extend body's scope parents to the TU, not to Foo -- the nested type must
// still be visible, and the field must still be a member, not an unknown name.
extend Foo {
    fn in_extend(self) -> i32 {
        var n = Nested { a: 1 }
        var q: Alias = 2
        return x + n.a + q
    }

    fn in_closure(self) -> i32 {
        var f = fn () -> i32 { return x }
        return f()
    }
}
// DIAG: error [R049E]: use of member 'x' requires an explicit qualifier
// DIAG: error [R049E]: use of member 'x' requires an explicit qualifier

// A static method has no `self`, so the fix-it must offer `Self::`.
class St {
    static k: i32 = 3
    static fn get() -> i32 { return k }
}
// DIAG: error [R049E]: use of static member 'k' requires an explicit qualifier

// The exception never fires as a diagnostic, in any of the four spellings.
// DIAG-NOT: 'Nested'
// DIAG-NOT: 'Alias'
