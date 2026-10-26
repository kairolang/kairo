// G5 (Compiler/Sema/NULLABLE.md 2.1): `x?` is the null test, typed `bool`,
// and lowers to `!x.is_null()` (NullTestLowering, through null_test_of).
// Covered: a value `i32?`, a pointer `(*i32)?`, a record `W?`, a call's
// result, `(i32?)?` (only the OUTER level is tested: a present outer
// holding a null inner is present), `if` and `while` conditions, `&&`,
// a plain `bool` value outside any condition, `!x?` (folded into
// `x.is_null()`, not `!!`), `not x?`, `!(x?)`, and a generic body's `t?` on
// a `T?`. Each check prints, so a wrong branch shows which one.
// Regression for the ticket "Postfix `?` null check is untyped": every `?`
// here was SC066E "unary operator '?' is not defined on 'i32?'".

import std::io::println

class W {
    pub var id: i32
    pub fn W(self, id: i32) { self.id = id }
}

fn find(k: i32) -> i32? {
    if k > 0 { return k }
    return null
}

fn nest(k: i32) -> (i32?)? {
    if k > 1 { var v: i32? = k; return v }
    if k == 1 { var v: i32? = null; return v }   // present outer, null inner
    return null
}

fn <T> present(t: T?) -> bool { return t? }

fn say(label: string, b: bool) {
    if b { println(f"{label}: yes") } else { println(f"{label}: no") }
}

fn main() -> i32 {
    var a = find(3)
    var b = find(0)
    say("a?", a?)
    say("b?", b?)
    say("!b?", !b?)
    say("not a?", not a?)
    say("!(a?)", !(a?))
    say("find(2)?", find(2)?)
    var v = a?                          // a plain bool
    say("v", v)

    var x = 5
    var p: (*i32)? = &x
    var q: (*i32)? = null
    say("p? && !q?", p? && !q?)

    var w: W? = W(1)
    var wn: W? = null
    say("w?", w?)
    say("wn?", wn?)

    say("nest(2)?", nest(2)?)
    say("nest(1)?", nest(1)?)           // outer present
    say("nest(0)?", nest(0)?)

    say("present(a)", present(a))
    say("present(b)", present(b))

    var c = find(1)
    var i = 0
    while c? {
        i += 1
        if i == 3 { c = null }
    }
    var r = 0
    if a? { r += 1 }
    if !b? { r += 2 }
    if i == 3 { r += 4 }
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG-NOT: error
// DIAG: null_test.k:24:26: warning [S055W]: nested nullable
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX:      template<class T> bool present( ::builtin::Nullable<T> t) {
// CXX-NEXT:     return(!t.is_null());
// CXX:      "!b?"{{.*}}, b.is_null());
// CXX:      "!(a?)"{{.*}}, a.is_null());
// CXX:      bool v =(!a.is_null());
// CXX:      "p? && !q?"{{.*}},((!p.is_null()) && q.is_null()));
// CXX-NOT:  !!
// CXX:      while((!c.is_null()))

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out; test $? -eq 7
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// OUT:      a?: yes
// OUT-NEXT: b?: no
// OUT-NEXT: !b?: yes
// OUT-NEXT: not a?: no
// OUT-NEXT: !(a?): no
// OUT-NEXT: find(2)?: yes
// OUT-NEXT: v: yes
// OUT-NEXT: p? && !q?: yes
// OUT-NEXT: w?: yes
// OUT-NEXT: wn?: no
// OUT-NEXT: nest(2)?: yes
// OUT-NEXT: nest(1)?: yes
// OUT-NEXT: nest(0)?: no
// OUT-NEXT: present(a): yes
// OUT-NEXT: present(b): no
