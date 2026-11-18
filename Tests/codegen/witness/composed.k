// witness/composed.k -- exit 26
// A composed interface as a bound. Cursor = (Readable + Seekable +
// Closable) - Closable: File has no `close` and conforms anyway, since the
// difference removed it. Shared = Readable & Cursor is just `read`. Each
// call goes through the BOUND's witness (Cursor_witness / Shared_witness),
// whose members are the composed list, and the concept lists exactly it.
pub interface Readable { fn read(self) -> i32 }
pub interface Seekable { fn seek(self, at: i32) }
pub interface Closable { fn close(self) }
pub interface Cursor derives (Readable + Seekable + Closable) - Closable { }
pub interface Shared derives Readable & Cursor { }

pub class File {
    pub var pos: i32 = 0
    fn File(self) { }
}
extend File {
    pub fn read(self) -> i32 { self.pos += 5; return self.pos; }
    pub fn seek(self, at: i32) { self.pos = at; }
}
pub fn <T impl Cursor> rewind_and_read(c: *T) -> i32 {
    c->seek(3)
    return c->read()
}
pub fn <T impl Shared> twice(s: *T) -> i32 = s->read() + s->read()

fn main() -> i32 {
    var f = File()
    var a = rewind_and_read(&f)
    return a + twice(&f) - 13
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: CODEGEN C++: {{.*}}witness/composed.k
// CXX: concept Cursor_c = requires(__kairo_Self * __kairo_r0, __kairo_Self * __kairo_r1, signed int __kairo_a0) {
// CXX-NOT: close
// CXX: concept Shared_c = requires(__kairo_Self * __kairo_r0) {
// CXX: Cursor_witness<T>::seek(c, 3);
// CXX: Cursor_witness<T>::read(c);
// CXX: Shared_witness<T>::read(s)

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 26
