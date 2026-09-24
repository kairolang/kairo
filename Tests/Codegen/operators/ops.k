// Every user-operator form through the whole pipeline: X records the overload
// (resolved_op / op_rewrite), OperatorLowering rewrites the node into the
// call, CXXSpell names it, and the emitted C++ links and runs.
//
//   member    op + / op == / op <=> / op as / op in / op r++
//   derived   != from ==, < and >= from <=>, += from +, + from +=
//   free      op *  found from the declaring file, not through a module
//   extend    op -  a free function named __kairo_op_neg
//   lang      ^^    the pow lang item, an integer and a float base

struct Vec2 {
    var x: f64
    var y: f64

    fn op +(self, other: Vec2) -> Vec2 { return Vec2{ x: self.x + other.x, y: self.y + other.y } }
    fn op ==(self, other: Vec2) -> bool { return (self.x == other.x) && (self.y == other.y) }
    fn op <=>(self, other: Vec2) -> Ordering {
        if self.x < other.x { return Ordering::Less }
        if self.x > other.x { return Ordering::Greater }
        if self.y < other.y { return Ordering::Less }
        if self.y > other.y { return Ordering::Greater }
        return Ordering::Equal
    }
    fn op as(self) -> f64 { return self.x + self.y }
    fn op in(self, k: f64) -> bool { return (self.x == k) || (self.y == k) }
    fn op r++(self) -> Vec2 {
        var old = Vec2{ x: self.x, y: self.y }
        self.x = self.x + 1.0
        return old
    }
}

// Declares `+=` only; `+` is derived (copy, mutate, yield).
struct Acc {
    var total: i32
    fn op +=(self, n: i32) { self.total = self.total + n }
}

// Free, at file scope beside its type: reachable through the declaring file.
fn op *(k: f64, v: Vec2) -> Vec2 { return Vec2{ x: k * v.x, y: k * v.y } }

extend Vec2 {
    fn op -(self) -> Vec2 { return Vec2{ x: 0.0 - self.x, y: 0.0 - self.y } }
}

fn main() -> i32 {
    var a = Vec2{ x: 1.0, y: 2.0 }
    var b = Vec2{ x: 3.0, y: 4.0 }

    var sum    = a + b                              // { 4, 6 }
    var scaled = 2.0 * sum                          // { 8, 12 }      -> 20
    var neg    = -sum                               // { -4, -6 }     -> -10
    var ne: i32  = if sum != a { 1 } else { 0 }     // derived !=     -> 1
    var lt: i32  = if a < b { 1 } else { 0 }        // derived <      -> 1
    var ge: i32  = if a >= b { 1 } else { 0 }       // derived >=     -> 0
    var has: i32 = if 4.0 in sum { 1 } else { 0 }   // op in          -> 1
    sum += a                                        // sum = sum + a  -> { 5, 8 }
    var old = sum++                                 // old { 5, 8 } -> 13, sum { 6, 8 } -> 14

    var acc = Acc{ total: 0 }
    acc += 5                                        // op += directly
    var acc2 = acc + 7                              // derived +      -> 12

    var p: i32 = 2 ^^ 5                             // 32
    var q: f64 = 1.5 ^^ 2                           // 2.25 -> 2
    var r: i32 = 2 ^^ -1                            // 0

    // 20 - 10 + 1 + 1 + 0 + 1 + 14 + 13 + 12 + 32 + 2 + 0 == 86
    return ((scaled as f64) as i32) + ((neg as f64) as i32) + ne + lt + ge + has
         + ((sum as f64) as i32) + ((old as f64) as i32) + acc2.total + p + (q as i32) + r
}

// --- lit wiring -----------------------------------------------------------
// At the BOTTOM: the CHECK prefixes assert declaration text and the
// arithmetic above is what the exit code encodes.

// RUN: { %kairo %s --type-check-only --print-cxx 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-DAG: Vec2 operator+(
// CXX-DAG: bool operator==(
// CXX-DAG: Ordering operator<=>(
// CXX-DAG: operator double(
// CXX-DAG: bool __kairo_contains(double
// CXX-DAG: Vec2 operator++(int)
// CXX-DAG: void operator+=(
// CXX-DAG: Vec2 operator*(double
// CXX-DAG: Vec2 __kairo_op_neg(
// CXX-DAG: pow
// CXX-NOT: operator-(

// REQUIRES: clang
// `-o` names a DIRECTORY: the entry TU's object, plus one per builtin TU it
// pulled in; the Slice and pow instances are homed in whichever used them.
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.d
// RUN: %clangxx %t.d/*.o %t.d/builtin/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 86