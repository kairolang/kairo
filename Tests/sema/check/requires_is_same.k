// Two types a generic body knows only by their bounds (`A` and `B`,
// `J::Item` and `T`) are different types unless a `requires
// __builtin_is_same` of the declaration equates them: the conversion is
// SC028E in the generic itself. A use whose arguments do not meet the
// clause is SC300E at the use, for a function and for a class.

interface Source {
    type Item
    fn next(self) -> Self::Item
}

class Count {
    var n: i32 = 0
}

extend Count impl Source {
    type Item = i32
    fn next(self) -> i32 { return self.n }
}

class Half {
    var h: f64 = 0.5
}

extend Half impl Source {
    type Item = f64
    fn next(self) -> f64 { return self.h }
}

fn <A, B> unbound(b: B) -> A {
    return b
}

fn <T, J impl Source> unbound_assoc(it: J, seed: T) -> T {
    var x: T = it.next()
    return x
}

// The clause equates A with B, not with C.
fn <A, B, C> other_pair(c: C) -> A requires __builtin_is_same<A, B>() {
    return c
}

fn <A, B> same(b: B) -> A requires __builtin_is_same<A, B>() {
    return b
}

fn <T, J impl Source> first(it: J, seed: T) -> T
  requires __builtin_is_same<J::Item, T>() && sizeof T >= 4 {
    return it.next()
}

class <I impl Source, J impl Source> Chain requires __builtin_is_same<J::Item, I::Item>() {
    var a: I
    var b: J
}

fn main() -> i32 {
    var ok: i32 = same<i32, i32>(1)
    var bad: i32 = same<i32, i64>(1)
    var good = first(Count{}, 0)
    var wrong = first(Half{}, 0)
    var small = first(Count{}, 0 as i8)
    var c = Chain<Count, Count>{a: Count{}, b: Count{}}
    var d = Chain<Count, Half>{a: Count{}, b: Half{}}
    return ok + good
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: requires_is_same.k:31:12: error [SC028E]: cannot convert 'B' to 'A'
// CHECK: requires_is_same.k:35:16: error [SC028E]: cannot convert 'J::Item' to 'T'
// CHECK: requires_is_same.k:41:12: error [SC028E]: cannot convert 'C' to 'A'
// CHECK-NOT: SC028E
// CHECK: requires_is_same.k:60:20: error [SC300E]: 'same<i32, i64>' cannot be used: its 'requires' clause does not hold
// CHECK-NEXT: requires_is_same.k:44:36: note [SC300N]: this is false for A = i32, B = i64
// CHECK: requires_is_same.k:62:17: error [SC300E]: 'first<i32, Half>' cannot be used: its 'requires' clause does not hold
// CHECK-NEXT: requires_is_same.k:49:12: note [SC300N]: this is false for T = i32, J = Half
// CHECK: requires_is_same.k:63:17: error [SC300E]: 'first<i8, Count>' cannot be used: its 'requires' clause does not hold
// CHECK: requires_is_same.k:65:{{[0-9]+}}: error [SC300E]: 'Chain<Count, Half>' cannot be used: its 'requires' clause does not hold
// CHECK-NEXT: requires_is_same.k:53:{{[0-9]+}}: note [SC300N]: this is false for I = Count, J = Half
// CHECK-NOT: error
