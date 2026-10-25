// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: conformance_base_missing.k:30:12: error [SC001E]: 'File' does not conform to 'Stream': no member 'read' with the requirement's signature
// CHECK: conformance_base_missing.k:24:9: note [I900N]: required by this bound
// CHECK: conformance_base_missing.k:12:5: note [I900N]: 'read' is required here
//
// `impl Stream` promises everything Stream derives: its requirement list
// holds Readable's `read` with its own `seek` (InterfaceComposition), so
// File, meeting only `seek`, fails Stream itself at the call -- never left
// to clang's constraint failure (CODEGEN.md §7b.10).

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
