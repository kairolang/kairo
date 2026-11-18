// The Sema agreement pass compares how a callee was found. Kairo's Sema
// does argument-dependent lookup itself and records a call it bound that
// way; where clang found its callee by argument-dependent lookup and the
// record does not say Sema did, the stream left the lookup to clang: I012W
// even though both reached one declaration.
//
// `tag(v, i)` is found by ADL in Sema (ordinary lookup sees only the Kairo
// `tag`, which would need i32 -> bool) and written qualified, so clang
// needs no ADL. `-v` is a free C++ operator Sema finds the same way and CodeGen
// writes as C++ looks it up, unqualified: clang finds it by ADL, and the
// record agrees. So do the `begin` and `end` of a range-for over a C++
// type whose only ones are hidden friends. The hidden --test-sema-agreement-no-adl withholds what
// Sema recorded.

ffi "c++" import "adl_ns.h"

fn tag(v: ns::V, x: bool) -> i32 { return 50 }

fn main() -> i32 {
    var v: ns::V
    v.x = 4
    var i: i32 = 1
    var w = -v
    var q: ns::Seq
    var n: i32 = 0
    for x in q { n += x } // 15
    return tag(v, i) + w.x + n - 15 // 5 + -4
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -v -fsema-agreement -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=AGREE
// AGREE-NOT: I012W
// AGREE: sema agreement: {{.*}} 3 found by ADL (3 by Sema too), 0 disagreed in {{.*}}adl_lookup.k
// AGREE-NOT: I012W
// RUN: %t.exe; test $? -eq 1
//
// RUN: rm -rf %t.d
// RUN: %kairo %s -fsema-agreement --sema-agreement-summary -o %t.exe --cache-dir %t.d --test-sema-agreement-no-adl 2>&1 | %FileCheck %s --check-prefix=LOOKUP
// LOOKUP: kairo: sema agreement: 3 finding(s) in 1 of {{[0-9]+}} file(s) (adl 3)
// LOOKUP: adl_lookup.k:23:13: warning [I012W]: internal: clang found 'ns::operator-(V)' for this call by argument-dependent lookup, but Kairo's Sema found 'operator-' by its name alone; this is a compiler bug
// LOOKUP-NEXT: adl_ns.h:11:10: note [I900N]: both reached this declaration
// LOOKUP: adl_lookup.k:{{[0-9]+}}:5: warning [I012W]: internal: clang found 'ns::begin(Seq &)' for this call by argument-dependent lookup
// LOOKUP: adl_lookup.k:{{[0-9]+}}:5: warning [I012W]: internal: clang found 'ns::end(Seq &)' for this call by argument-dependent lookup
// RUN: %t.exe; test $? -eq 1
//
// From the cache, the same.
// RUN: %kairo %s -fsema-agreement --sema-agreement-summary -o %t.exe --cache-dir %t.d --test-sema-agreement-no-adl 2>&1 | %FileCheck %s --check-prefix=LOOKUP
