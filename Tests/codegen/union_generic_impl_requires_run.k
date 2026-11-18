// A generic union with a declared `impl` and a `requires` clause: the
// instance conforms through the declaration (its `op ==` is not public), the
// clause is met by the argument, and a bounded generic call runs on the
// union's operator.

interface Same {
    fn op ==(const self, o: Self) -> bool
}

struct Key impl Same {
    var id: u64

    fn op ==(const self, o: Key) -> bool { return self.id == o.id }
}

union <T> Slot impl Same requires T impl Same {
    var value: T
    var raw:   u64

    fn op ==(const self, o: Slot<T>) -> bool { return self.raw == o.raw }
}

fn <T> eq(x: T, y: T) -> bool requires T impl Same {
    return x == y
}

fn main() -> i32 {
    var a: Slot<Key>
    a.raw = 5
    var b: Slot<Key>
    b.raw = 5
    var c: Slot<Key>
    c.raw = 6
    if eq(a, b) && !eq(a, c) {
        return 13
    }

    return 1
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 13
