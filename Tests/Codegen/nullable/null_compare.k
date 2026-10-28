// G6 (Compiler/Sema/NULLABLE.md 2.2): the four comparisons with `null`
// run as the null test they desugar to -- `x == null` / `null == x` is
// `x.is_null()`, `x != null` / `null != x` is `!x.is_null()` -- on a value,
// a record, a call's result and a nullable pointer, where `&null` is the
// same null as `null` (1.3). Before G5/G6 every one of them ICEd in EmitIR
// ("user operator; OperatorLowering must rewrite it into a call"): the
// lowered `null` made the comparison a record operator nobody rewrote.
//
// `a == b` with BOTH operands `i32?` is not a null test: it is the
// Nullable's own C++ `operator==` (present on Nullable<T> when T has
// `==`): equal when both are null, or both present with equal values. It is
// pinned here as it behaves today. (On a record payload with a Kairo
// `op ==` it does not type-check yet; ticketed.)

import std::io::println

class W {
    pub var id: i32
    pub fn W(self, id: i32) { self.id = id }
}

fn find(k: i32) -> i32? {
    if k > 0 { return k }
    return null
}

fn say(label: string, b: bool) {
    if b { println(f"{label}: yes") } else { println(f"{label}: no") }
}

fn main() -> i32 {
    var a = find(3)
    var z = find(0)
    say("a == null", a == null)
    say("null == a", null == a)
    say("a != null", a != null)
    say("null != a", null != a)
    say("z == null", z == null)
    say("null != z", null != z)
    say("(z) == null", (z) == null)
    say("!(z == null)", !(z == null))
    say("find(1) != null", find(1) != null)

    var w: W? = W(1)
    say("w == null", w == null)

    var x = 5
    var p: (*i32)? = &x
    var q: (*i32)? = null
    say("p == &null", p == &null)
    say("&null != p", &null != p)
    say("q == &null", q == &null)
    say("q == null", q == null)

    var five: i32? = 5
    var six: i32? = 6
    var n1: i32? = null
    var n2: i32? = null
    say("null == null", n1 == n2)
    say("5 == null", five == n1)
    say("5 == 5", five == find(5))
    say("5 == 6", five == six)
    say("5 != 6", five != six)

    var r = 0
    var c = find(1)
    while c != null { r += 1; c = null }
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX:      "a == null"{{.*}}, a.is_null());
// CXX:      "null != a"{{.*}},(!a.is_null()));
// CXX:      "p == &null"{{.*}}, p.is_null());
// CXX:      "5 == 6"{{.*}},(five == six));
// CXX:      while((!c.is_null()))

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out; test $? -eq 1
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// OUT:      a == null: no
// OUT-NEXT: null == a: no
// OUT-NEXT: a != null: yes
// OUT-NEXT: null != a: yes
// OUT-NEXT: z == null: yes
// OUT-NEXT: null != z: no
// OUT-NEXT: (z) == null: yes
// OUT-NEXT: !(z == null): no
// OUT-NEXT: find(1) != null: yes
// OUT-NEXT: w == null: no
// OUT-NEXT: p == &null: no
// OUT-NEXT: &null != p: yes
// OUT-NEXT: q == &null: yes
// OUT-NEXT: q == null: yes
// OUT-NEXT: null == null: yes
// OUT-NEXT: 5 == null: no
// OUT-NEXT: 5 == 5: yes
// OUT-NEXT: 5 == 6: no
// OUT-NEXT: 5 != 6: yes
