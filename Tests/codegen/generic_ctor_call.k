// A constructor call inside a generic body names its type, and is typed with
// it: the callee record is dependent, the argument is not.
//
// `again` is a record calling its own constructor; `make` is one generic
// record calling another's, the YieldPromise<T> -> Yield<T> shape. Both put
// an Exact non-dependent constructor against the `Self` transfer
// constructor, which is assumed viable and unranked -- the Exact one has to
// win, or every generic record is ambiguous at its definition.

class <T> Box {
    pub var p: unsafe *void
    pub var v: T

    pub fn Box(self, p: unsafe *void) { self.p = p }
    @move fn Box(self, other: Self) { self.p = other.p; other.p = &null }

    pub fn again(self) -> Box<T> {
        return Box<T>(self.p)
    }
}

class <T> Maker {
    pub fn make(self, p: unsafe *void) -> Box<T> {
        return Box<T>(p)
    }
}

fn main() -> i32 {
    var x: i32 = 5
    var m = Maker<i32> {}
    var b = m.make(unsafe (&x as unsafe *void))
    var c = b.again()
    unsafe { return *(c.p as unsafe *i32) }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: return{{.*}}Box<T>(
// CXX: return{{.*}}Box<T>(

// REQUIRES: clang
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s -c --cache-dir %t.d/k
// RUN: %clangxx %t.d/k/*.o %t.d/k/builtin/*.o %t.d/k/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 5
