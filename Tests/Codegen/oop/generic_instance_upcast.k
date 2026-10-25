// A generic class deriving a generic base with its own parameter
// (`class <T> Const derives Source<T>`, classes.md, Generic Classes): an
// instance upcasts to the matching base instance and dispatches through it.
//
// XFAIL: *
// Waiting on the base list of a generic instance being substituted:
// `var s: *Source<i32> = &k` with k a Const<i32> is SC028E "cannot convert
// '*Const<i32>' to '*Source<i32>'". A non-generic `derives Source<i32>`
// upcasts fine (generic_virtual_base.k).
// When it lands this test XPASSes; delete the XFAIL -- the run below is
// already the real assertion.

class <T> Source {
    virtual fn get(self) -> i32 { return 0 }
}

class <T> Const derives Source<T> {
    var v: i32
    fn Const(self, v: i32) { self.v = v }
    override fn get(self) -> i32 { return self.v }
}

fn main() -> i32 {
    var k = Const<i32>(41)
    var s: *Source<i32> = &k
    return s->get()
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 41
