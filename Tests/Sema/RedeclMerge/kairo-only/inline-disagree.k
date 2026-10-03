// NO ORACLE: C++ lets a later declaration add `inline`. Kairo does not,
// because `inline` decides where the body is EMITTED: an importer reads it
// off the in-class declaration, the home TU off the definition, and a chain
// that disagrees leaves the importer calling a body no object is sure to
// hold.
//
// EXPECT-ERROR: 15: modifier-disagreement (inline)
// EXPECT-ERROR: 16: modifier-disagreement (inline)
// EXPECT-ERROR: 19: modifier-disagreement (inline)

class Bar {
    inline fn b(self) -> i32
    fn c(self) -> i32
}
fn Bar::b(self) -> i32 { return 2 }
inline fn Bar::c(self) -> i32 { return 3 }

fn later(x: i32) -> i32
inline fn later(x: i32) -> i32 { return x }

// Agreeing chains are fine, in class and at file scope.
class Ok {
    inline fn a(self) -> i32
}
inline fn Ok::a(self) -> i32 { return 1 }
inline fn both(x: i32) -> i32
inline fn both(x: i32) -> i32 { return x }

// --- lit wiring -----------------------------------------------------------
// Kept at the BOTTOM on purpose: the EXPECT-ERROR annotations above name
// absolute LINE NUMBERS in the code.
//
// One error per mistake: the mismatch on `b` poisons its definition, and the
// no-body rule must not then report `b` a second time.
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: inline-disagree.k:15:1: error [R039E]: 'b' redeclared with a different 'inline' qualifier
// CHECK: inline-disagree.k:16:1: error [R039E]: 'c' redeclared with a different 'inline' qualifier
// CHECK: inline-disagree.k:19:1: error [R039E]: 'later' redeclared with a different 'inline' qualifier
// CHECK-NOT: error
