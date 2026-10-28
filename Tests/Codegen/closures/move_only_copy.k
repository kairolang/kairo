// Copying a `fn` value that holds a closure with a move-only capture: the
// lambda cannot be copied, and the type `fn() -> i32` cannot say so, so
// the copy traps at run time (CODEGEN.md §6, Closures). Pinned so a
// change to that choice is deliberate.

@move class Handle {
    pub var id: i32 = 0
    fn Handle(self, id: i32) { self.id = id }
    @move fn Handle(self, other: Self) { self.id = other.id; other.id = 0 }
}

fn main() -> i32 {
    var h = Handle(5)
    var f = fn () -> i32 { return h.id }
    var g = f
    return g()
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: not --crash %t.exe
