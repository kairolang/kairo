class Buf {
    var data: [i32; 2] = [1, 2]
    pub fn begin(self) -> *i32 { return &self.data[0] }
    pub fn end(self) -> *i32 { return &self.data[1] }
}

fn f(b: Buf) {
    for x in b { }
}

// A Kairo class with C++-style begin()/end() is not iterable: those are
// ordinary methods, and `op in` is the only way to make a Kairo type
// iterable, so the message names only it.

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG:     user_begin_end_err.k:8:14: error [SC095E]: 'Buf' is not iterable; it has no 'op in (self) -> yield T'{{$}}
// DIAG-NOT: {{error|warning}} [
