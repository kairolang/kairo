// An extension's bound on an associated type (`requires S::Item impl
// Copyable`) at an instance whose item is a primitive: the instance carries
// the row, so the primitive's Copyable witness is emitted in the unit that
// checks the bound. Without the row clang refused the call to copy() ("'unsigned
// char' cannot be used prior to '::'"), as no other use of the program named
// a byte's copy.

interface Next {
    type Item
    fn next(self) -> Self::Item
}

class <T> Src impl Next {
    type Item = T
    pub var v: T

    fn next(self) -> T {
        return self.v
    }
}

class <S impl Next> Dup {
    pub var s: S
}

extend <S impl Next> Dup<S> requires S::Item impl Copyable {
    fn take(self) -> S::Item {
        var x = self.s.next()
        return x.copy()
    }
}

fn main() -> i32 {
    var d = Dup<Src<u8>> { s: Src<u8> { v: 7 } }
    var e = Dup<Src<i64>> { s: Src<i64> { v: 5 } }
    return (d.take() as i32) + (e.take() as i32) - 12
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -f %t.exe
// RUN: { %kairo_new %s -o %t.exe 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty --implicit-check-not='error'
// RUN: %t.exe
// DIAG-NOT: Copyable_c
