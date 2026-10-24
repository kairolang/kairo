// witness/derives.k -- exit 7
// A call bound to a BASE interface's requirement goes through the base's
// witness (CODEGEN.md §7b.9): `impl Stream` yields a row for Stream and for
// Readable, and Stream's concept conjoins Readable's.
pub interface Readable {
    fn read(self) -> i32
}
pub interface Stream derives Readable {
    fn seek(self, at: i32)
}
pub class File {
    pub var pos: i32 = 0
    fn File(self) { }
}
extend File {
    pub fn read(self) -> i32 { self.pos += 5; return self.pos; }
    pub fn seek(self, at: i32) { self.pos = at; }
}
pub fn <T impl Stream> pump(s: *T) -> i32 {
    s->seek(2)
    return s->read()
}
fn main() -> i32 {
    var f = File()
    return pump(&f)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: CODEGEN C++: {{.*}}witness/derives.k
// CXX-DAG: concept Stream_c = {{ ?}}::{{.*}}::Readable_c<__kairo_Self> && requires(
// CXX-DAG: template<> struct Readable_witness<{{ ?}}::{{.*}}::File> {
// CXX-DAG: template<> struct Stream_witness<{{ ?}}::{{.*}}::File> {
// A pointer receiver is passed as it is.
// CXX: Stream_witness<T>::seek(s, 2);
// CXX: Readable_witness<T>::read(s);

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 7
