// One of the constructs Compiler/ is written with, checked on Stage 1 ahead
// of self-hosting (2026-10-24 probe; tickets in private/IMPORTANT/TICKETS.TXT).
//
// A class generic over a constant, the TokenBuffer shape
// (`class <const CHUNK_SIZE: usize> TokenBuffer`, ~100 uses of
// TokenBuffer::<512>): the constant sizes an array field and is read as a
// value.
//
// XFAIL: *
// Waiting on codegen spelling a constant generic parameter: it type-checks
// and ICEs ("CXXSpell: type with no canonical reached codegen").
// When it lands this test XPASSes; delete the XFAIL -- the run below is
// already the real assertion.

class <const N: usize> Buf {
    var data: [i32; N]
    fn cap(const self) -> usize { return N }
    fn put(self, i: usize, v: i32) { self.data[i] = v }
    fn get(self, i: usize) -> i32 { return self.data[i] }
}

fn main() -> i32 {
    var b = Buf<4>()
    b.put(3, 3)
    var r = b.get(3)
    if b.cap() == 4 { r += 4 }
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 7
