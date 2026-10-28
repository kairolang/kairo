// Local declarations and generics. A local `fn`, class or enum inside a
// generic function is emitted at namespace scope like any other, and a
// local that is generic in its own right becomes a namespace-scope template
// -- which a C++ local class could never hold (no member templates). What is
// not supported yet is a local that names the ENCLOSING function's (or
// class's) parameter: Sema/Check/local_decl_outer_generic.k.

fn <T> pair_sum(a: T, b: T) -> i32 {
    fn base() -> i32 { return 100 }                     // names no T
    class Tally { pub var n: i32 = 1 }
    var t = Tally()
    return base() + t.n
}

fn uses_generic_local() -> i32 {
    fn <U> first(a: U, b: U) -> U { return a }          // its own <U>
    class <V> Box {
        pub var v: V
        fn Box(self, v: V) { self.v = v }
        fn <W> with(self, w: W) -> W { return w }        // a member template
    }
    var b = Box<i32>(7)
    return first<i32>(3, 4) + b.v + b.with<i32>(10)      // 3 + 7 + 10
}

class <K> Keeper {
    pub var k: K
    fn Keeper(self, k: K) { self.k = k }
    fn count(self) -> i32 {
        fn one() -> i32 { return 1 }                     // in a generic class's method
        return one() + one()
    }
}

fn main() -> i32 {
    var n = 0
    if pair_sum<i32>(1, 2) == 101       { n += 1 }
    if pair_sum<f64>(1.0, 2.0) == 101   { n += 1 }
    if uses_generic_local() == 20       { n += 1 }
    var kp = Keeper<i32>(5)
    if kp.count() == 2                  { n += 1 }
    return n                                             // 4
}

// --- lit wiring -----------------------------------------------------------

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error [
// DIAG-NOT: warning [
// END-GENERATED-CHECKS(DIAG)

// BEGIN-GENERATED-CHECKS(EXEC) mode=run -- regenerate with Tests/gen_checks.py, do not hand-edit
// REQUIRES: clang
// RUN: rm -rf %t.exec.d
// RUN: %kairo %s -o %t.exec.exe --cache-dir %t.exec.d
// RUN: %t.exec.exe > %t.exec.out; test $? -eq 4
// RUN: test ! -s %t.exec.out
// END-GENERATED-CHECKS(EXEC)
