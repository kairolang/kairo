// `finally()` on a copy-only type and on a type that can be neither copied
// nor moved (Compiler/Spec/Lowering.md#union-storage-locals). The union
// storage is an aggregate, so `var p = make_pinned(1)` builds the object
// in place exactly as a plain `T x = make_pinned(1)` does: no copy or move
// constructor is needed or called.
import std::io::println

class CopyOnly {
    var id: i32 = 0
    fn CopyOnly(self, id: i32) { self.id = id }
    @copy fn CopyOnly(self, const other: Self) { self.id = other.id + 100 }
    fn op finally(self) { println(f"~CopyOnly {self.id}") }
}

class Pinned {
    var id: i32 = 0
    fn Pinned(self, id: i32) { self.id = id }
    @copy fn Pinned(self, const other: Self) = delete
    @move fn Pinned(self, other: Self) = delete
    fn op finally(self) { println(f"~Pinned {self.id}") }
}

fn make_pinned(id: i32) -> Pinned {
    return Pinned(id)
}

fn copies(c: bool) {
    var a = CopyOnly(1)
    var b = a
    if c {
        a.finally()
    }
    b.finally()
    println("copies")
}

fn pinned(c: bool) {
    var p = make_pinned(2)
    var q = Pinned(3)
    if c {
        p.finally()
    }
    q.finally()
    println("pinned")
}

fn main() -> i32 {
    copies(true)
    copies(false)
    pinned(true)
    pinned(false)
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// OUT:      ~CopyOnly 1
// OUT-NEXT: ~CopyOnly 101
// OUT-NEXT: copies
// OUT-NEXT: ~CopyOnly 101
// OUT-NEXT: copies
// OUT-NEXT: ~CopyOnly 1
// OUT-NEXT: ~Pinned 2
// OUT-NEXT: ~Pinned 3
// OUT-NEXT: pinned
// OUT-NEXT: ~Pinned 3
// OUT-NEXT: pinned
// OUT-NEXT: ~Pinned 2
// OUT-EMPTY:
