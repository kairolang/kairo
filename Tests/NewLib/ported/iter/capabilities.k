// Which chains are ExactSize and which are DoubleEnded. A chain asks for
// `remaining()` and `next_back()` only where every link provides them:
// `map`, `enumerate`, `zip`, `take`, `skip`, `rev` and `copied` keep ExactSize;
// `filter`, `filter_map`, `flat_map`, `chain`, `take_while` and `skip_while`
// do not, because they cannot know how many items they pass on. `map`,
// `filter`, `enumerate`, `zip`, `take`, `skip`, `rev`, `copied` and `chain`
// keep DoubleEnded; `take_while` and `skip_while` do not. The calls in
// `not_sized` and `not_double_ended` are rejected at their own line;
// `sized` and `double_ended` compile.
//
// `filter_map`, `flat_map`, `step_by` and `peekable` have no DoubleEnded
// extension and `step_by` and `peekable` no ExactSize one in
// Lib/std2/iter.k, where the Rust adapters have them; nothing asserts their
// absence here.
//
// Cases from Rust library/coretests/tests/iter/adapters/ (the size and
//   double-ended assertions of each adapter's file, with `len()` as
//   `remaining()`) and traits/double_ended.rs

import std::iter::*

fn yes(x: *const i64) -> bool = true
fn same(x: i64) -> i64 = x
fn maybe(x: i64) -> i64? = x
fn many(x: i64) -> Span = Span(x)

class Span {
    var lo: i64
    var hi: i64

    pub fn Span(self, n: i64) {
        self.lo = 0
        self.hi = n
    }
}

extend Span impl Iterator {
    type Item = i64
    fn next(self) -> i64? {
        if self.lo == self.hi {
            return null
        }

        self.lo += 1
        return self.lo - 1
    }
}

extend Span impl DoubleEnded {
    fn next_back(self) -> i64? {
        if self.lo == self.hi {
            return null
        }

        self.hi -= 1
        return self.hi
    }
}

extend Span impl ExactSize {
    fn remaining(const self) -> usize = (self.hi - self.lo) as usize
}

fn sized() -> usize {
    var n: usize = 0
    n += iter(Span(5)).remaining()
    n += iter(Span(5)).map<i64>(same).remaining()
    n += iter(Span(5)).enumerate().remaining()
    n += iter(Span(5)).zip(Span(3)).remaining()
    n += iter(Span(5)).take(2).remaining()
    n += iter(Span(5)).skip(2).remaining()
    n += iter(Span(5)).rev().remaining()
    n += iter(Span(5)).skip(1).take(2).enumerate().map<(usize, i64)>(same_pair).rev().remaining()
    return n
}

fn same_pair(x: (usize, i64)) -> (usize, i64) = x

fn not_sized() -> usize {
    var n: usize = 0
    n += iter(Span(5)).filter(yes).remaining()
    n += iter(Span(5)).filter_map<i64>(maybe).remaining()
    n += iter(Span(5)).flat_map<Span>(many).remaining()
    n += iter(Span(5)).chain(Span(2)).remaining()
    n += iter(Span(5)).take_while(yes).remaining()
    n += iter(Span(5)).skip_while(yes).remaining()
    n += iter(Span(5)).map<i64>(same).filter(yes).remaining()
    return n
}

fn double_ended() {
    var a? = iter(Span(5)).map<i64>(same).next_back()
    var b? = iter(Span(5)).filter(yes).next_back()
    var c? = iter(Span(5)).enumerate().next_back()
    var d? = iter(Span(5)).zip(Span(3)).next_back()
    var e? = iter(Span(5)).take(2).next_back()
    var f? = iter(Span(5)).skip(2).next_back()
    var g? = iter(Span(5)).rev().next_back()
    var h? = iter(Span(5)).chain(Span(2)).next_back()
}

fn not_double_ended() {
    var c? = iter(Span(5)).take_while(yes).next_back()
    var d? = iter(Span(5)).skip_while(yes).next_back()
}

fn main() -> i32 {
    return (sized() + not_sized()) as i32
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: { %kairo_new --type-check-only %s --cache-dir %t.d || true; } 2>&1 | %FileCheck %s
// CHECK-NOT: capabilities.k:{{(6[4-9]|7[0-8])}}:
// CHECK: capabilities.k:81:{{[0-9]+}}: error [SC162E]: 'Filter<Span>' does not conform to 'ExactSize'
// CHECK: capabilities.k:82:{{[0-9]+}}: error [SC162E]: 'FilterMap<Span, i64>' does not conform to 'ExactSize'
// CHECK: capabilities.k:83:{{[0-9]+}}: error [SC162E]: 'FlatMap<Span, Span>' does not conform to 'ExactSize'
// CHECK: capabilities.k:84:{{[0-9]+}}: error [SC162E]: 'Chain<Span, Span>' does not conform to 'ExactSize'
// CHECK: capabilities.k:85:{{[0-9]+}}: error [SC162E]: 'TakeWhile<Span>' does not conform to 'ExactSize'
// CHECK: capabilities.k:86:{{[0-9]+}}: error [SC162E]: 'SkipWhile<Span>' does not conform to 'ExactSize'
// CHECK: capabilities.k:87:{{[0-9]+}}: error [SC162E]: 'Filter<Map<Span, i64>>' does not conform to 'ExactSize'
// CHECK-NOT: capabilities.k:{{(8[89]|9[0-9]|100)}}:
// CHECK: capabilities.k:103:{{[0-9]+}}: error [SC162E]: 'TakeWhile<Span>' does not conform to 'DoubleEnded'
// CHECK: capabilities.k:104:{{[0-9]+}}: error [SC162E]: 'SkipWhile<Span>' does not conform to 'DoubleEnded'
