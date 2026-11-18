// Run: a move-only value behind a nullable is moved exactly once, whether it
// is read through a narrowed place, unwrapped, coalesced or assigned, and
// each object is destroyed once (nullables.mdx, Narrowing: a known non-null
// nullable is used as its `T`; Force unwrap). `Tracked` counts its
// constructions, moves and destructions; every case ends with
// constructed + moved == destroyed and no live object. A failure prints the case name; the exit status is the
// number of failures.
// Cases from Kotlin compiler/testData/diagnostics/tests/smartCasts/
// (varnotnull/, safecalls/) and nullabilityAndSmartCasts/ where the value is
// consumed after the check, adapted to a move-only class.

import std::io::println

var failures = 0
var ctors = 0
var moves = 0
var dtors = 0

fn check(const name: string, got: i32, want: i32) {
    if got != want {
        println(f"FAIL {name}: got {got} want {want}")
        failures += 1
    }
}

fn reset() { ctors = 0; moves = 0; dtors = 0 }
fn balanced(const name: string) { check(name, ctors + moves - dtors, 0) }

class Tracked {
    pub var id: i32
    pub fn Tracked(self, id: i32) { self.id = id; ctors += 1 }
    @move fn Tracked(self, other: Self) { self.id = other.id; other.id = 0; moves += 1 }
    fn op finally(self) { dtors += 1 }
}

fn make(id: i32) -> Tracked? { if id > 0 { return Tracked(id) } return null }
fn sink(@move t: Tracked) -> i32 { return t.id }
fn peek(const t: Tracked) -> i32 { return t.id }
fn sink_if_present(t: Tracked?) -> i32 {
    if t? { return sink(t) }
    return -1
}
fn sink_after_early_exit(t: Tracked?) -> i32 {
    if !t? { return -1 }
    return sink(t)
}
fn pass_nullable(@move t: Tracked?) -> i32 {
    if t? { return t.id }
    return -1
}
fn coalesce_call(id: i32) -> i32 {
    var r = make(id) ?? Tracked(100)
    return r.id
}

fn main() -> i32 {
    reset()
    {
        var w: Tracked? = Tracked(5)
        if w? { check("sink narrowed", sink(w), 5) }
    }
    check("sink narrowed moves", moves, 1)
    balanced("sink narrowed balanced")

    reset()
    check("sink_if_present", sink_if_present(Tracked(6)), 6)
    check("sink_if_present null", sink_if_present(null), -1)
    balanced("sink_if_present balanced")

    reset()
    check("sink_after_early_exit", sink_after_early_exit(Tracked(7)), 7)
    check("sink_after_early_exit null", sink_after_early_exit(null), -1)
    balanced("sink_after_early_exit balanced")

    reset()
    {
        var u = unwrap!(make(8))
        check("unwrap call result", u.id, 8)
    }
    check("unwrap call result ctors", ctors, 1)
    balanced("unwrap call result balanced")

    reset()
    {
        var w: Tracked? = Tracked(9)
        var u = unwrap!(w)
        check("unwrap place", u.id, 9)
    }
    balanced("unwrap place balanced")

    reset()
    check("peek narrowed const", peek(unwrap!(make(11))), 11)
    balanced("peek balanced")

    reset()
    check("pass nullable present", pass_nullable(Tracked(12)), 12)
    check("pass nullable null", pass_nullable(null), -1)
    balanced("pass nullable balanced")

    reset()
    check("coalesce present", coalesce_call(13), 13)
    check("coalesce null", coalesce_call(0), 100)
    balanced("coalesce balanced")

    reset()
    {
        var w: Tracked? = null
        w = Tracked(14)
        if w? { check("assigned then read", w.id, 14) }
        w = null
        balanced("assigned null destroys the payload")
    }
    balanced("assign balanced")

    reset()
    {
        var w: Tracked? = Tracked(15)
        w = Tracked(16)
        check("overwrite", w.id, 16)
    }
    balanced("overwrite balanced")

    reset()
    for k in 0..4 {
        var e? = make(k)
        if !e? { continue }
        check("loop element", sink(e), k)
    }
    balanced("loop balanced")

    if failures != 0 { println(f"{failures} failed") }
    return failures
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty --implicit-check-not='error [' --implicit-check-not='warning ['

// REQUIRES: clang
// RUN: rm -rf %t.d %t.o2.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe
