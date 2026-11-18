// Run: closures, globals and checked downcasts over nullables. A closure
// that captures by copy holds the value the variable had when the closure
// was made, and a closure that assigns its copy keeps the assigned value from
// one call to the next; a pointer capture sees the variable's current value
// and its writes; a global read after a check and before the next call has
// the checked value (nullables.mdx, Closures and stored pointers; Globals and
// statics; casting.mdx, Checked downcast). A failure prints the case name; the
// exit status is the number of failures.
// Cases from Kotlin compiler/testData/diagnostics/tests/smartCasts/
// (varnotnull/varCapturedInClosure, lambdaDeclaresAndModifies,
// lambdas/inPlaceLambdas, noErrorCheckForPackageLevelVal).

import std::io::println

var failures = 0

fn check(const name: string, got: i32, want: i32) {
    if got != want {
        println(f"FAIL {name}: got {got} want {want}")
        failures += 1
    }
}

class Animal { pub virtual fn name(self) -> i32 { return 1 } pub fn Animal(self) { } }
class Dog derives Animal { pub fn fetch(self) -> i32 { return 2 } pub fn Dog(self) { } }
class Cat derives Animal { pub fn Cat(self) { } }

var gcount: i32? = null
var gcalls = 0

fn find(k: i32) -> i32? { if k > 0 { return k } return null }
fn touch() { gcount = null; gcalls += 1 }
fn set_global(k: i32) { gcount = find(k) }

fn global_after_check() -> i32 {
    set_global(4)
    if gcount? { return gcount + 1 }
    return -1
}

fn global_after_call_recheck() -> i32 {
    set_global(4)
    if gcount? {
        var first? = gcount
        touch()
        if gcount? { return gcount }
        return first + 100
    }
    return -1
}

fn copy_capture(x: i32?) -> i32 {
    if !x? { return -1 }
    var f = fn ()|x| -> i32 { return x + 1 }
    return f()
}

fn copy_capture_is_a_snapshot() -> i32 {
    var x: i32? = 5
    var f = fn ()|x| -> i32 { if x? { return x } return -1 }
    x = null
    return f()
}

fn copy_capture_assigned_persists() -> i32 {
    var x: i32? = 1
    var f = fn ()|x| -> i32 {
        if x? { x = x + 10 } else { x = 0 }
        if x? { return x }
        return -1
    }
    var a = f()
    var b = f()
    return a * 1000 + b
}

fn pointer_capture_sees_writes() -> i32 {
    var x: i32? = 1
    var f = fn ()|*x| -> i32 {
        if (*x)? { return (*x) }
        return -1
    }
    var a = f()
    x = 7
    var b = f()
    x = null
    var c = f()
    return a * 10000 + b * 100 + (c + 1)
}

fn pointer_capture_writes_outer() -> i32 {
    var x: i32? = 3
    var clear = fn ()|*x| { *x = null }
    var r = 0
    if x? { r += x }
    clear()
    if x? { r += 1000 }
    return r
}

fn pointer_capture_restore() -> i32 {
    var x: i32? = null
    var set = fn (v: i32)|*x| { *x = v }
    set(9)
    if x? { return x }
    return -1
}

fn checked_downcast(a: *Animal) -> i32 {
    var *d? = a as *Dog?
    if d? { return d->fetch() }
    return -1
}

fn main() -> i32 {
    check("global after check", global_after_check(), 5)
    check("global after call recheck", global_after_call_recheck(), 104)
    check("copy capture", copy_capture(4), 5)
    check("copy capture null", copy_capture(null), -1)
    check("copy capture snapshot", copy_capture_is_a_snapshot(), 5)
    check("copy capture assigned persists", copy_capture_assigned_persists(), 11 * 1000 + 21)
    check("pointer capture sees writes", pointer_capture_sees_writes(), 1 * 10000 + 7 * 100 + 0)
    check("pointer capture writes outer", pointer_capture_writes_outer(), 3)
    check("pointer capture restore", pointer_capture_restore(), 9)

    var dog = Dog()
    var cat = Cat()
    check("downcast dog", checked_downcast(&dog), 2)
    check("downcast cat", checked_downcast(&cat), -1)

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
