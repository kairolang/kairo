// A member type named through a CONCRETE instance in type position is
// resolved there, not left dependent (GH#73). `Foo<i32>::Inner` in a
// function with no generic context of its own used to break out of
// TypeResolve's chain walk as Dependent: the node was flagged dependent and
// every conversion of `x` was deferred. It is now the instance's Inner, so
// the conversions below are checked and name it, and the TU's type table has
// no dependent node at all (Foo's body never mentions T).

class <T> Foo {
    var v: i32
    class Inner { var q: i32 }
}

fn g() -> i32 {
    var x: Foo<i32>::Inner
    x.q = 3
    var s: string = x
    var t: string = x.q
    return x.q
}

// --- lit wiring -----------------------------------------------------------

// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:17:21: error [SC028E]: cannot convert 'Foo<i32>::Inner' to 'string'
// DIAG: {{.*}}:18:21: error [SC028E]: cannot convert 'i32' to 'string'

// RUN: { %kairo %s --type-check-only --print-sema 2>&1 || true; } | %FileCheck %s --check-prefix=SEMA
// SEMA-LABEL: SEMA fid 0: {{.*}}nested_instance_concrete.k
// SEMA: -- types --
// SEMA-NEXT: {{[0-9]+}} type node(s): {{[0-9]+}} canonical, 0 of them dependent, 0 errored
