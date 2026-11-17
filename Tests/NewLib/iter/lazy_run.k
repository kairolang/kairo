// How many items each chain pulls from its source. `Source` counts every
// call of its `next` and every call made after it returned null: a chain
// pulls nothing until it is consumed, never pulls an item it does not pass
// on or test, and never asks a source again once the source has ended.

import std::iter::*
import std::io

var pulls: i64 = 0
var overruns: i64 = 0
var failed: i32 = 0

/// Yields 0, 1, ... n - 1.
class Source {
    var at:    i64
    var end:   i64
    var ended: bool

    pub fn Source(self, n: i64) {
        self.at    = 0
        self.end   = n
        self.ended = false
    }
}

extend Source impl Iterator {
    type Item = i64
    fn next(self) -> i64? {
        pulls += 1
        if self.ended {
            overruns += 1
        }

        if self.at == self.end {
            self.ended = true
            return null
        }

        self.at += 1
        return self.at - 1
    }
}

/// Pulls counted since the last call; resets the count.
fn pulled(const label: string, want: i64) {
    if pulls != want {
        failed += 1
        io::println(f"FAILED {label}: pulled {pulls}, expected {want}")
    }

    pulls = 0
}

fn hold(const label: string, cond: bool) {
    if !cond {
        failed += 1
        io::println(f"FAILED {label}")
    }
}

fn twice(x: i64) -> i64 = x * 2
fn even(x: *const i64) -> bool = (*x & 1) == 0
fn below_three(x: *const i64) -> bool = *x < 3
fn is_two(x: *const i64) -> bool = *x == 2
fn source_to(x: i64) -> Source = Source(x)
fn add(a: i64, x: i64) -> i64 = a + x
fn ignore(x: i64) { }

fn building_pulls_nothing() {
    var a = iter(Source(9)).map<i64>(twice).filter(even).skip(2).take(3).step_by(2).enumerate()
    var b = iter(Source(9)).take_while(below_three).skip_while(below_three).peekable()
    var c = iter(Source(9)).chain(Source(9)).zip(Source(9)).flat_map<Source>(pair_source)
    pulled("building a chain", 0)
}

fn pair_source(p: (i64, i64)) -> Source = Source(p.0)

fn take_stops_at_its_count() {
    hold("take 3 count", iter(Source(10)).take(3).count() == 3)
    pulled("take(3) of 10", 3)
    hold("take 0 count", iter(Source(10)).take(0).count() == 0)
    pulled("take(0) of 10", 0)
    hold("take 9 of 2", iter(Source(2)).take(9).count() == 2)
    pulled("take(9) of 2", 3)
    hold("map take", iter(Source(10)).map<i64>(twice).take(2).fold<i64>(0, add) == 2)
    pulled("map.take(2)", 2)
    hold("take map", iter(Source(10)).take(2).map<i64>(twice).fold<i64>(0, add) == 2)
    pulled("take(2).map", 2)
    hold("filter take", iter(Source(10)).filter(even).take(2).count() == 2)
    pulled("filter(even).take(2)", 3)
    hold("take filter", iter(Source(10)).take(2).filter(even).count() == 1)
    pulled("take(2).filter(even)", 2)
    hold("enumerate take", iter(Source(10)).enumerate().take(4).count() == 4)
    pulled("enumerate.take(4)", 4)
}

fn skip_and_step() {
    hold("skip take", iter(Source(10)).skip(2).take(2).fold<i64>(0, add) == 5)
    pulled("skip(2).take(2)", 4)
    hold("take skip", iter(Source(10)).take(4).skip(1).count() == 3)
    pulled("take(4).skip(1)", 4)
    hold("skip past", iter(Source(3)).skip(9).count() == 0)
    pulled("skip(9) of 3", 4)
    hold("step take", iter(Source(10)).step_by(3).take(2).fold<i64>(0, add) == 3)
    pulled("step_by(3).take(2)", 4)
    hold("step all", iter(Source(7)).step_by(3).count() == 3)
    pulled("step_by(3) of 7", 8)
}

fn predicates() {
    hold("take_while", iter(Source(10)).take_while(below_three).count() == 3)
    pulled("take_while(< 3) of 10", 4)
    hold("take_while all", iter(Source(2)).take_while(below_three).count() == 2)
    pulled("take_while(< 3) of 2", 3)
    hold("skip_while take", iter(Source(10)).skip_while(below_three).take(1).count() == 1)
    pulled("skip_while(< 3).take(1)", 4)

    var tw = iter(Source(10)).take_while(below_three)
    while tw.next()? { }

    pulled("take_while drained", 4)
    hold("take_while stays ended", !tw.next()? && !tw.next()?)
    pulled("take_while after its end", 0)
}

fn two_sources() {
    hold("zip short b", iter(Source(5)).zip(Source(2)).count() == 2)
    pulled("zip(5, 2)", 6)
    hold("zip short a", iter(Source(2)).zip(Source(5)).count() == 2)
    pulled("zip(2, 5)", 5)
    hold("chain", iter(Source(2)).chain(Source(3)).count() == 5)
    pulled("chain(2, 3)", 7)
    hold("chain take", iter(Source(2)).chain(Source(3)).take(1).count() == 1)
    pulled("chain(2, 3).take(1)", 1)
    hold("chain take 3", iter(Source(2)).chain(Source(3)).take(3).count() == 3)
    pulled("chain(2, 3).take(3)", 4)
    hold("flat_map", iter(Source(4)).flat_map<Source>(source_to).count() == 6)
    pulled("flat_map of 4", 5 + 1 + 2 + 3 + 4)
    hold("flat_map take", iter(Source(4)).flat_map<Source>(source_to).take(1).count() == 1)
    pulled("flat_map.take(1)", 2 + 1 + 1)
}

fn peeking() {
    var p = iter(Source(2)).peekable()
    pulled("peekable built", 0)
    var *a? = p.peek()
    var *b? = p.peek()
    hold("peek twice", a? && b? && *unwrap!(a) == 0 && *unwrap!(b) == 0)
    pulled("peek twice", 1)
    hold("next after peek", (p.next() ?? -1) == 0)
    pulled("next after peek", 0)
    hold("next", (p.next() ?? -1) == 1)
    pulled("next", 1)
    hold("peek at the end", !p.peek()?)
    pulled("peek at the end", 1)
    hold("peek and next after the end", !p.peek()? && !p.next()? && !p.peek()?)
    pulled("peek and next after the end", 0)
}

fn consumers_stop_early() {
    hold("find", (iter(Source(10)).find(is_two) ?? -1) == 2)
    pulled("find(== 2)", 3)
    hold("position", (iter(Source(10)).position(is_two) ?? 99) == 2)
    pulled("position(== 2)", 3)
    hold("any", iter(Source(10)).any(is_two))
    pulled("any(== 2)", 3)
    hold("all", !iter(Source(10)).all(below_three))
    pulled("all(< 3)", 4)
    hold("nth", (iter(Source(10)).nth(2) ?? -1) == 2)
    pulled("nth(2)", 3)
    hold("nth past", !iter(Source(2)).nth(5)?)
    pulled("nth(5) of 2", 3)
    hold("last", (iter(Source(4)).last() ?? -1) == 3)
    pulled("last of 4", 5)
    iter(Source(3)).for_each(ignore)
    pulled("for_each of 3", 4)
    hold("reduce", (iter(Source(4)).reduce(add) ?? -1) == 6)
    pulled("reduce of 4", 5)
    hold("sum", iter(Source(4)).sum() == 6)
    pulled("sum of 4", 5)
}

fn main() -> i32 {
    building_pulls_nothing()
    take_stops_at_its_count()
    skip_and_step()
    predicates()
    two_sources()
    peeking()
    consumers_stop_early()
    if overruns != 0 {
        failed += 1
        io::println(f"FAILED a source was asked {overruns} times after its end")
    }

    return failed
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: rm -rf %t.d
// RUN: %kairo_new -O2 %s -o %t.O2.exe --cache-dir %t.d
// RUN: %t.O2.exe
