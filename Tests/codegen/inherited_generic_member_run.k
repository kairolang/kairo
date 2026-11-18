// A member inherited from a generic base is called through the derived
// instance with the base instance's parameter type: `Const<i32>().put(1)`
// is `Source<i32>::put(i32)`. The program builds at -O0 and -O2 and exits 6.

class <T> Source {
    pub var last: T
    fn put(self, x: T) { self.last = x }
}

class <T> Const derives Source<T> { }

fn main() -> i32 {
    var c = Const<i32>()
    c.put(6)
    return c.last
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error
// REQUIRES: clang
// RUN: rm -rf %t.d %t.exe
// RUN: %kairo %s -O0 -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 6
// RUN: rm -rf %t.d2 %t2.exe
// RUN: %kairo %s -O2 -o %t2.exe --cache-dir %t.d2
// RUN: %t2.exe; test $? -eq 6
