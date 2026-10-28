// witness/derives.k -- exit 7
// A call bound to an INHERITED requirement goes through the BOUND's witness:
// every interface's requirement list holds what it derives
// (InterfaceComposition), so `T impl Stream` calling `read` is
// `Stream_witness<T>::read`, Stream's row covers read and seek both, and
// Stream's concept lists every requirement rather than conjoining Readable's.
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
// CXX: concept Stream_c = requires(__kairo_Self * __kairo_r0, __kairo_Self * __kairo_r1, signed int __kairo_a0) {
// CXX-NOT: template<> struct Readable_witness
// CXX: template<> struct Stream_witness<{{ ?}}::{{.*}}::File> {
// A pointer receiver is passed as it is.
// CXX: Stream_witness<T>::seek(s, 2);
// CXX: Stream_witness<T>::read(s);

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 7
