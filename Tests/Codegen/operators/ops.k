// Every user-operator form through the whole pipeline: X records the overload
// (resolved_op), OperatorLowering rewrites the node into the call, CXXSpell
// names it `operator<sym>`, and the emitted C++ links and runs.
//
// Five forms, one program:
//   member   `op +`   Vec2 + Vec2
//   member   `op ==`  Vec2 == Vec2
//   free     `op *`   f64 * Vec2   (ADL through the right operand)
//   extend   `op -`   -Vec2        (unary, on an extension)
//   cast     `op as`  Vec2 as f64
//
// KNOWN FAILURE, and not of this feature: an operator declared INSIDE a record
// body does not resolve its own parameter type -- `a + b` reports
// "no matching overload for call to 'op +'" with "candidate not viable:
// parameter type is unresolved". It reproduces on the release binary, so it
// predates the operator-lowering work. Until that is fixed, `op +` and `op ==`
// below have to move into the `extend` block (which resolves correctly) or
// this test needs an XFAIL. Left in member position on purpose: this file is
// the statement of what the surface is meant to be.

struct Vec2 {
    var x: f64
    var y: f64

    fn op +(self, other: Vec2) -> Vec2 { return Vec2{ x: self.x + other.x, y: self.y + other.y } }
    fn op ==(self, other: Vec2) -> bool { return (self.x == other.x) && (self.y == other.y) }
    fn op as(self) -> f64 { return self.x + self.y }
}

// Free, found by ADL through its second operand.
fn op *(k: f64, v: Vec2) -> Vec2 { return Vec2{ x: k * v.x, y: k * v.y } }

extend Vec2 {
    fn op -(self) -> Vec2 { return Vec2{ x: 0.0 - self.x, y: 0.0 - self.y } }
}

fn main() -> i32 {
    var a: Vec2 = Vec2{ x: 1.0, y: 2.0 }
    var b: Vec2 = Vec2{ x: 3.0, y: 4.0 }

    var sum: Vec2    = a + b            // op +      -> { 4, 6 }
    var scaled: Vec2 = 2.0 * sum        // free op * -> { 8, 12 }
    var c: Vec2      = Vec2{ x: 8.0, y: 12.0 }
    var eq: bool     = scaled == c      // op ==     -> true
    var neg: Vec2    = -sum             // op -      -> { -4, -6 }

    // A block `if` cannot start a continuation line: the parser ends the
    // statement at the previous line and reads the `+` as a new one. Bound
    // to a var, which the sum reads as an operand like any other.
    var bonus: i32 = if eq { 1 } else { 0 }

    // op as on each: 10 + (-10) + 20 + 1 == 21. On ONE line: a continuation
    // line that STARTS with `+` does not parse (the statement ends at the
    // previous line), which is older than this test and not what it asserts.
    return ((sum as f64) as i32) + ((neg as f64) as i32) + ((scaled as f64) as i32) + bonus
}

// --- lit wiring -----------------------------------------------------------
// At the BOTTOM: the CHECK prefixes below assert declaration text, and the
// arithmetic above is what the exit code encodes -- anything inserted between
// them would separate the two halves of one assertion.

// The interface: each operator named the way C++ spells it. `op as` becomes a
// conversion operator, whose name IS its target type.
// RUN: { %kairo %s --type-check-only --print-cxx 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-DAG: Vec2 operator+(
// CXX-DAG: bool operator==(
// CXX-DAG: operator double(
// CXX-DAG: Vec2 operator*(double
// CXX-DAG: Vec2 operator-(

// The object links against a real C++ driver and runs. 21 is the value the
// comment above derives; a wrong operator picks a different one rather than
// failing to link, which is the whole point of checking the exit code.
// REQUIRES: clang
// `-o` names a DIRECTORY: the entry TU's object, plus one per builtin TU
// it pulled in. The Slice instance is homed in whichever of those used it,
// so all of them go to the linker.
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.d
// RUN: %clangxx %t.d/*.o %t.d/builtin/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 21
