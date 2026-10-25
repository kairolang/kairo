// A derived pointer passed to a generic function with EXPLICIT arguments:
// `pull<i32>(&c)` with `fn <T> pull(s: *Source<T>)` and c a Counter that
// derives Source<i32>. With T given, the parameter is *Source<i32> and the
// ordinary derived-to-base conversion applies.
//
// XFAIL: *
// Waiting on viability using the substituted parameter type: today it is
// SC063E, the note reading "cannot convert argument of type '*Counter' to
// parameter 's' of type '*Source<T>'" -- T is still unsubstituted. The
// deduced call `pull(sp)` on an already-upcast pointer works
// (generic_virtual_base.k).
// When it lands this test XPASSes; delete the XFAIL -- the run below is
// already the real assertion.

class <T> Source {
    virtual fn get(self) -> i32 { return 0 }
}

class Counter derives Source<i32> {
    override fn get(self) -> i32 { return 9 }
}

fn <T> pull(s: *Source<T>) -> i32 { return s->get() }

fn main() -> i32 {
    var c = Counter()
    return pull<i32>(&c)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 9
