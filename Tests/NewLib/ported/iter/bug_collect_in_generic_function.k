// `collect` on a chain whose element type is a generic parameter of the
// calling function is rejected as ambiguous between the two declarations in
// Lib/std2/iter.k (the plain one under `requires !(I impl ExactSize)` and
// the sized one), for sized chains and for chains that are not (a `filter`
// chain hits it too): the clause is not evaluated for a dependent chain
// type. With a concrete element type the same call is accepted. Expected:
// it compiles and collects the items.

import std::iter::*
import self::Inputs::probe::*

fn <E impl Elem> collect_both(n: i64) -> [E] {
    return iter(Both<E>(n)).collect<[E]>()
}

fn main() -> i32 {
    var v = collect_both<i64>(4)
    expect(ints_are(v, [0, 1, 2, 3]), "collect in a generic function")
    return finish()
}

// --- lit wiring ---
// REQUIRES: newlib
// XFAIL: *
// RUN: rm -rf %t.d
// RUN: rm -f %t.exe %t.o2.exe
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %kairo_new %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe
