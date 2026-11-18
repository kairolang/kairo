// Run: the evaluation rules of the nullable operators (nullables.mdx: Safe
// access, Null coalescing, Null-aware equality, Force unwrap). `??` evaluates
// its right side only when the left is null, `?.` evaluates the call and its
// arguments only on the non-null path and yields null otherwise, a chain
// `a?.b?.c` applies each step to the previous result, `===` compares values
// only when both are present, and `unwrap!` evaluates its operand once. Each
// `check` compares a result with the value the source says; a failure prints
// the case name and the exit status is the number of failures.
// Cases from Kotlin compiler/testData/diagnostics/tests/smartCasts/elvis/,
// smartCasts/safecalls/ (receiver, argument, insideCall, chainAndUse,
// longChain), smartCasts/bangbang and nullabilityAndSmartCasts/AssertNotNull.

import std::io::println

var failures = 0
var calls = 0

fn check(const name: string, got: i32, want: i32) {
    if got != want {
        println(f"FAIL {name}: got {got} want {want}")
        failures += 1
    }
}

fn b2i(b: bool) -> i32 { if b { return 1 } return 0 }
fn find(k: i32) -> i32? { calls += 1; if k > 0 { return k } return null }
fn arg(k: i32) -> i32 { calls += 1; return k }

class Net {
    pub var port: i32 = 80
    pub fn Net(self) { }
    pub fn scaled(self, k: i32) -> i32 { return self.port * k }
}
class Config {
    pub var timeout: i32 = 30
    pub var retries: i32? = null
    pub var net: Net? = null
    pub fn Config(self) { }
    pub fn save(self, k: i32) -> bool { return k > 0 }
    pub fn touch(self) { self.timeout += 1 }
}

fn make(on: bool) -> Config? { calls += 1; if on { return Config() } return null }

fn main() -> i32 {
    // ?? : the right side runs only on null
    calls = 0
    check("coalesce present", find(3) ?? arg(9), 3)
    check("coalesce present calls", calls, 1)
    calls = 0
    check("coalesce null", find(0) ?? arg(9), 9)
    check("coalesce null calls", calls, 2)
    calls = 0
    check("coalesce chain first", find(1) ?? find(2) ?? arg(3), 1)
    check("coalesce chain first calls", calls, 1)
    calls = 0
    check("coalesce chain second", find(0) ?? find(2) ?? arg(3), 2)
    check("coalesce chain second calls", calls, 2)
    calls = 0
    check("coalesce chain last", find(0) ?? find(0) ?? arg(3), 3)
    check("coalesce chain last calls", calls, 3)
    var n: i32? = null
    var m: i32? = 4
    check("coalesce nullable rhs null", n ?? m ?? 0, 4)
    n = 7
    check("coalesce zero is a value", (0 as i32?) ?? 5, 0)
    check("coalesce local", n ?? 1, 7)

    // ?. : null when the receiver is null, nothing to the right is evaluated
    calls = 0
    var c? = make(true)
    if !c? { return 100 }
    check("safe member", c?.timeout ?? -1, 30)
    var d? = make(false)
    check("safe member null", d?.timeout ?? -1, -1)
    calls = 0
    check("safe call arg evaluated", b2i(c?.save(arg(1)) ?? false), 1)
    check("safe call arg evaluated calls", calls, 1)
    calls = 0
    check("safe call arg skipped", b2i(d?.save(arg(1)) ?? true), 1)
    check("safe call arg skipped calls", calls, 0)
    check("safe call result false", b2i(c?.save(arg(0)) ?? true), 0)
    check("safe nullable member", c?.retries ?? -2, -2)
    c.retries = 5
    check("safe nullable member set", c?.retries ?? -2, 5)
    check("safe chain null middle", c?.net?.port ?? -3, -3)
    c.net = Net()
    check("safe chain full", c?.net?.port ?? -3, 80)
    check("safe chain call", c?.net?.scaled(2) ?? -3, 160)
    check("safe chain null head", d?.net?.port ?? -3, -3)
    c?.touch()
    d?.touch()
    check("safe statement ran on present", c.timeout, 31)
    calls = 0
    check("safe on call result", make(true)?.timeout ?? -1, 30)
    check("safe on call result null", make(false)?.timeout ?? -1, -1)
    check("safe on call result calls", calls, 2)
    check("safe result is null", b2i(d?.timeout == null), 1)
    check("safe result not null", b2i(c?.timeout != null), 1)

    // === : both present and equal
    var a: i32? = 3
    var b: i32? = 3
    var z: i32? = null
    check("triple eq equal", b2i(a === b), 1)
    check("triple eq differ", b2i(a === (4 as i32?)), 0)
    check("triple eq lhs null", b2i(z === b), 0)
    check("triple eq both null", b2i(z === z), 0)
    check("triple eq literal", b2i(a === 3), 1)
    check("triple eq literal differ", b2i(a === 4), 0)
    check("double eq both null", b2i(z == z), 1)
    check("double eq null differ", b2i(z == a), 0)
    var s = 0
    if a === b { s = a + b }
    check("triple eq narrows", s, 6)

    // unwrap! evaluates once and leaves the place proven
    calls = 0
    check("unwrap call once", unwrap!(find(8)), 8)
    check("unwrap call once calls", calls, 1)
    var u: i32? = 12
    var w = unwrap!(u)
    check("unwrap then read", u + w, 24)
    c.net = Net()
    unwrap!(c.net).port = 99
    check("unwrap lvalue", c.net.port, 99)

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
