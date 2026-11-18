// Run: `unwrap!` on null aborts the process (status 134, SIGABRT) after
// writing "unwrap!(<expression>) on null at <file>:<line>:<column>" to
// stderr; it is not a panic and nothing after it runs (nullables.mdx, Force
// unwrap). The case is picked by the number of command-line arguments: with
// none, every unwrap is on a present value and the program exits 0; with n
// arguments, case n unwraps a null: a local, a call result, a field, a
// nullable pointer, a record, a place that was tested but not on the path
// taken, and a generic `T?`. Each case's stderr names its own expression.
// Cases from Kotlin compiler/testData/diagnostics/tests/smartCasts/bangbang
// and nullabilityAndSmartCasts/AssertNotNull.

import std::io::println

class Foo { pub var v: i32 = 1; pub fn Foo(self) { } }
class Holder { pub var n: i32? = null; pub var foo: Foo? = null; pub fn Holder(self) { } }

fn none() -> i32? { return null }
fn some() -> i32? { return 5 }
fn <T> force(t: T?) -> T { return unwrap!(t)}

fn present() -> i32 {
    var a: i32? = 1
    var h = Holder()
    h.n = 2
    h.foo = Foo()
    var k = 3
    var p: (*i32)? = &k
    var s = 0
    s += unwrap!(a)
    s += unwrap!(some())
    s += unwrap!(h.n)
    s += unwrap!(h.foo).v
    s += *unwrap!(p)
    s += force(a)
    return s
}

fn case_local() -> i32 {
    var z: i32? = null
    return unwrap!(z)
}

fn case_call() -> i32 {
    return unwrap!(none())
}

fn case_field() -> i32 {
    var h = Holder()
    return unwrap!(h.n)
}

fn case_pointer() -> i32 {
    var p: (*i32)? = null
    return *unwrap!(p)
}

fn case_record() -> i32 {
    var h = Holder()
    return unwrap!(h.foo).v
}

fn case_after_test(a: i32?) -> i32 {
    if a? { return a }
    return unwrap!(a)
}

fn case_generic() -> i32 {
    var z: i32? = none()
    return force(z)
}

fn main(argc: i32) -> i32 {
    if argc == 1 {
        if present() != 1 + 5 + 2 + 1 + 3 + 1 { return 99 }
        return 0
    }
    println("before")
    var r = 0
    if argc == 2 { r = case_local() }
    if argc == 3 { r = case_call() }
    if argc == 4 { r = case_field() }
    if argc == 5 { r = case_pointer() }
    if argc == 6 { r = case_record() }
    if argc == 7 { r = case_after_test(none()) }
    if argc == 8 { r = case_generic() }
    println("not reached")
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty --implicit-check-not='error ['

// REQUIRES: clang
// RUN: rm -rf %t.d %t.o2.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %t.o2.exe
// RUN: %t.exe a > %t.out 2> %t.err; test $? -eq 134
// RUN: %FileCheck %s --check-prefix=E2 --match-full-lines < %t.err
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// RUN: %t.exe a a > %t.out 2> %t.err; test $? -eq 134
// RUN: %FileCheck %s --check-prefix=E3 --match-full-lines < %t.err
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// RUN: %t.exe a a a > %t.out 2> %t.err; test $? -eq 134
// RUN: %FileCheck %s --check-prefix=E4 --match-full-lines < %t.err
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// RUN: %t.exe a a a a > %t.out 2> %t.err; test $? -eq 134
// RUN: %FileCheck %s --check-prefix=E5 --match-full-lines < %t.err
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// RUN: %t.exe a a a a a > %t.out 2> %t.err; test $? -eq 134
// RUN: %FileCheck %s --check-prefix=E6 --match-full-lines < %t.err
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// RUN: %t.exe a a a a a a > %t.out 2> %t.err; test $? -eq 134
// RUN: %FileCheck %s --check-prefix=E7 --match-full-lines < %t.err
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// RUN: %t.exe a a a a a a a > %t.out 2> %t.err; test $? -eq 134
// RUN: %FileCheck %s --check-prefix=E8 --match-full-lines < %t.err
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// RUN: %t.o2.exe a > %t.out 2> %t.err; test $? -eq 134
// RUN: %FileCheck %s --check-prefix=E2 --match-full-lines < %t.err
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// RUN: %t.o2.exe a a > %t.out 2> %t.err; test $? -eq 134
// RUN: %FileCheck %s --check-prefix=E3 --match-full-lines < %t.err
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// RUN: %t.o2.exe a a a > %t.out 2> %t.err; test $? -eq 134
// RUN: %FileCheck %s --check-prefix=E4 --match-full-lines < %t.err
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// RUN: %t.o2.exe a a a a > %t.out 2> %t.err; test $? -eq 134
// RUN: %FileCheck %s --check-prefix=E5 --match-full-lines < %t.err
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// RUN: %t.o2.exe a a a a a > %t.out 2> %t.err; test $? -eq 134
// RUN: %FileCheck %s --check-prefix=E6 --match-full-lines < %t.err
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// RUN: %t.o2.exe a a a a a a > %t.out 2> %t.err; test $? -eq 134
// RUN: %FileCheck %s --check-prefix=E7 --match-full-lines < %t.err
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// RUN: %t.o2.exe a a a a a a a > %t.out 2> %t.err; test $? -eq 134
// RUN: %FileCheck %s --check-prefix=E8 --match-full-lines < %t.err
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// E2: unwrap!(z) on null at {{.*}}unwrap_trap_run.k:40:12
// E3: unwrap!(none()) on null at {{.*}}unwrap_trap_run.k:44:12
// E4: unwrap!(h.n) on null at {{.*}}unwrap_trap_run.k:49:12
// E5: unwrap!(p) on null at {{.*}}unwrap_trap_run.k:54:13
// E6: unwrap!(h.foo) on null at {{.*}}unwrap_trap_run.k:59:12
// E7: unwrap!(a) on null at {{.*}}unwrap_trap_run.k:64:12
// E8: unwrap!(t) on null at {{.*}}unwrap_trap_run.k:19:35
// OUT: before
// OUT-NOT: not reached
