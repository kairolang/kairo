// Defaults become thunks: after a non-default parameter, before one, on a
// method (its thunk is a static member, so a private static is reachable),
// and on a generic function (a dependent default is a template body, and its
// instance is spelled and homed like any other).

fn chk(c: bool) -> i32 { if c { return 1 } return 0 }

fn f(a: i32, b: i32 = 7) -> i32 { return a * 10 + b }
fn late(a: i32 = 3, b: i32) -> i32 { return a * 10 + b }
fn <T> pick(a: T, b: T = T()) -> T { return a + b }

class Counter {
    var v: i32
    pub fn Counter(self, v: i32) { self.v = v }
    priv fn base() -> i32 { return 5 }
    pub fn add(self, x: i32 = Counter::base()) -> i32 { return self.v + x }
}

fn main() -> i32 {
    var c = Counter(10)
    var n = chk(f(1) == 17)
    n += chk(late(b: 4) == 34)
    n += chk(pick(5) == 5)
    n += chk(pick(2.5) == 2.5)
    n += chk(c.add() == 15)
    n += chk(c.add(1) == 11)
    return n
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// The thunks are declared: a free function per default, a static member for
// the method's, and a function template for the generic one. Its explicit
// instantiations are emitted after the bodies, not here; the link proves them.
// RUN: { %kairo %s --print-cxx 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-DAG: static signed int __kairo_default_add_x();
// CXX-DAG: signed int __kairo_default_f_b();
// CXX-DAG: signed int __kairo_default_late_a();
// CXX-DAG: template<class T> T __kairo_default_pick_b();

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -c --cache-dir %t.d
// RUN: %clangxx %t.d/*.o %t.d/builtin/*.o %t.d/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 6
