// Multiple inheritance (classes-inheritance.md): a class deriving two
// polymorphic bases overrides a virtual from each, and the upcast to the
// SECOND base adjusts the pointer -- the two base pointers to one object
// differ, and each still dispatches to the derived override.
//
// Addresses are compared as `unsafe *void`: `ptr as usize` does not
// compile yet (ptr_to_usize.k).

class Reader {
    prot var rv: i32
    virtual fn read(self) -> i32 { return self.rv }
}

class Writer {
    prot var wv: i32
    virtual fn write(self) -> i32 { return self.wv }
    virtual fn flush(self) -> i32 { return self.wv + 1 }
}

class File derives Reader, Writer {
    fn File(self) { self.rv = 1  self.wv = 2 }
    override fn read(self) -> i32 { return self.rv * 10 }
    override fn write(self) -> i32 { return self.wv * 50 }
}

fn main() -> i32 {
    var r = 0
    var f = File()
    var rd: *Reader = &f
    var wr: *Writer = &f
    if rd->read() == 10 { r += 1 }
    if wr->write() == 100 { r += 2 }
    if wr->flush() == 3 { r += 4 }              // second base's own virtual
    unsafe {
        var pr = rd as unsafe *void
        var pw = wr as unsafe *void
        var pf = (&f) as unsafe *void
        if pr == pf { r += 8 }                  // first base at offset 0
        if pw != pf { r += 16 }                 // second base is not
    }
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 31
