// A type where a value is required (P252). A name that denotes a type (`P`,
// `ns::Q`, a generic parameter `T`) or `typeof x` types to nothing by
// design -- the callee or member base that reads it takes it from the side
// table -- so every value consumer saw an unknown and let it through: the
// variable or argument reached codegen untyped, an operator ICEd. Each is
// SC094E now (typeof as a value is still the TypeInfo U001E, P113), with
// `()` offered for a record's name.
struct P { var x: i32 }
module ns { pub struct Q { var y: i32 } }

fn take(v: i32) { }
fn take_p(p: P) { }

fn f(x: i32) -> i32 {
    var i = P
    var q = ns::Q
    take(typeof x)
    take_p(P)
    var j = 1 + P
    var k: i32 = P
    x += P
    return P
}

fn <T> g(t: T) {
    var u = T
}

fn ok() -> i32 {
    var p = P()
    take_p(P())
    return p.x
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="Internal Compiler Error"
// DIAG:      type_as_value.k:15:13: error [SC094E]: 'P' is a type, not a value
// DIAG-NEXT: fix-it:"{{.*}}":{15:14-15:14}:"()"
// DIAG:      type_as_value.k:16:13: error [SC094E]: 'ns::Q' is a type, not a value
// DIAG-NEXT: fix-it:"{{.*}}":{16:18-16:18}:"()"
// DIAG:      type_as_value.k:17:10: error [SC271E]: 'typeof' as a value is a 'TypeInfo', which is not implemented yet
// DIAG:      type_as_value.k:18:12: error [SC094E]: 'P' is a type, not a value
// DIAG-NEXT: fix-it:"{{.*}}":{18:13-18:13}:"()"
// DIAG:      type_as_value.k:19:17: error [SC094E]: 'P' is a type, not a value
// DIAG:      type_as_value.k:20:18: error [SC094E]: 'P' is a type, not a value
// DIAG:      type_as_value.k:21:10: error [SC094E]: 'P' is a type, not a value
// DIAG:      type_as_value.k:22:12: error [SC094E]: 'P' is a type, not a value
// A parameter T has no one obvious value: no fix-it.
// DIAG:      type_as_value.k:26:13: error [SC094E]: 'T' is a type, not a value
// DIAG-NOT:  fix-it
