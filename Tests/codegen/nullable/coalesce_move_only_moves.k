// `x ?? y` with a payload that cannot be copied: a left operand that is a
// local or by-value parameter read for the last time moves into the
// result, and so does a right operand that is one. `x?.copy() ?? y` copies
// and leaves `x` as it was. Each case is checked at run time.

import std::io::*

fn param(r: string?) -> usize {
    var x = r ?? ""
    return x.size()
}

fn local() -> usize {
    var r: string? = "abc"
    return (r ?? "zz").size()
}

fn returned(r: string?) -> string {
    return r ?? "dflt"
}

fn right_local(r: string?, s: string) -> usize {
    var x = r ?? s
    return x.size()
}

fn right_nullable(a: string?, b: string?) -> usize {
    var x = a ?? b
    return (x ?? "").size()
}

fn chained(a: string?, b: string?) -> usize {
    return (a ?? b ?? "c").size()
}

fn container(m: {string: string}?) -> usize {
    var x = m ?? {}
    return x.size()
}

fn copied(r: string?) -> usize {
    var x = r?.copy() ?? ""
    var y = r ?? "q"
    return x.size() * 10 + y.size()
}

fn reassigned(xs: [string]) -> usize {
    var n: usize = 0
    var r: string? = null
    for x in xs {
        r = x.copy()
        n += (r ?? "").size()
    }
    return n
}

fn main() -> i32 {
    var m: {string: string} = {}
    m.insert("k", "v")
    println(f"{param("ab")} {param(null)} {local()} {returned(null)} {returned("x")}")
    println(f"{right_local(null, "abc")} {right_local("z", "abc")} {right_nullable(null, "zz")}")
    println(f"{chained(null, null)} {chained(null, "bb")} {container(m)} {container(null)}")
    println(f"{copied("ab")} {copied(null)} {reassigned(["a", "bb", "ccc"])}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// CHECK:      2 0 3 dflt x
// CHECK-NEXT: 3 1 2
// CHECK-NEXT: 1 2 1 0
// CHECK-NEXT: 22 1 6
