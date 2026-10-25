// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: conformance_composed.k:22:12: error [SC001E]: 'File' does not conform to 'Cursor': no member 'seek' with the requirement's signature
// CHECK-NOT: close
// CHECK-NOT: error
//
// A composed interface's requirement list is what a conformer must meet:
// `close` was subtracted, so missing it is fine; `seek` was kept, so
// missing it is the error, named against Cursor itself.

pub interface Readable { fn read(self) -> i32 }
pub interface Seekable { fn seek(self, at: i32) }
pub interface Closable { fn close(self) }
pub interface Cursor derives (Readable + Seekable + Closable) - Closable { }
pub class File {
    pub var pos: i32 = 0
    fn File(self) { }
}
extend File { pub fn read(self) -> i32 = self.pos }
pub fn <T impl Cursor> use_it(c: *T) -> i32 = c->read()
fn main() -> i32 {
    var f = File()
    return use_it(&f)
}
