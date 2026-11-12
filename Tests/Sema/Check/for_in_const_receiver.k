// `for x in m` resolves the iterable's `op in` on the iterable's own
// cv. Before, the const was dropped and a const map or set (whose builtin
// `op in` takes `self`) failed only in clang ("'__kairo_iter' ... not
// marked const"). Now the loop is SC063E, the same rule a call of a
// non-const method on a const object meets; `op in (const self)` iterates
// a const value as before. With several
// binders the const element reaches each one: `for (a, *b) in` over a
// const vector of tuples points `b` at a const element.

class Bag {
    var v: i32 = 0
    fn op in (self) -> yield i32 { yield self.v }
}

class Fine {
    var v: i32 = 0
    fn op in (const self) -> yield i32 { yield self.v }
}

fn over_param(const m: {i32: i32}) -> i32 {
    var s = 0
    for (k, v) in m { s += k + v }
    return s
}

fn main() -> i32 {
    const m: {i32: i32} = {1: 2}
    const st: {i32} = {3}
    const b = Bag()
    const fine = Fine()
    var s = 0
    for (k, v) in m { s += k + v }
    for e in st { s += e }
    for x in b { s += x }
    for y in fine { s += y }

    const ps: [(i32, i32)] = [(1, 2)]
    for (a, *c) in ps { *c = a }
    return s + over_param(m)
}

// --- lit wiring ---
// RUN: { %kairo --type-check-only %s 2>&1 || true; } | %FileCheck %s --implicit-check-not=error
// CHECK: for_in_const_receiver.k:22:19: error [SC063E]: no matching overload for call to 'op in'
// CHECK-NEXT: hash_map.k:{{[0-9]+}}:{{[0-9]+}}: note [I900N]: candidate not viable: 'op in' is not const; it cannot be called on a const object
// CHECK-NEXT: for_in_const_receiver.k:32:19: error [SC063E]: no matching overload for call to 'op in'
// CHECK-NEXT: hash_map.k:{{[0-9]+}}:{{[0-9]+}}: note [I900N]: candidate not viable: 'op in' is not const; it cannot be called on a const object
// CHECK-NEXT: for_in_const_receiver.k:33:14: error [SC063E]: no matching overload for call to 'op in'
// CHECK-NEXT: hash_set.k:{{[0-9]+}}:{{[0-9]+}}: note [I900N]: candidate not viable: 'op in' is not const; it cannot be called on a const object
// CHECK-NEXT: for_in_const_receiver.k:34:14: error [SC063E]: no matching overload for call to 'op in'
// CHECK-NEXT: for_in_const_receiver.k:12:5: note [I900N]: candidate not viable: 'op in' is not const; it cannot be called on a const object
// CHECK-NEXT: for_in_const_receiver.k:38:25: error [SC071E]: cannot assign to '*c': 'c' points to const
// CHECK-NEXT: for_in_const_receiver.k:38:14: note [I900N]: 'c' declared as a pointer to const here
