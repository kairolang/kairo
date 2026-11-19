// RUN: rm -rf %t.d
// RUN: { %kairo %s -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s
// Loosening Vector's copy constraint for a class still being defined
// must not let a vector of a COMPLETE move-only element be copied.
// Kairo reports it itself, before clang sees it.
// CHECK: error [SC162E]: 'MoveOnly' does not conform to 'Copyable': no member 'copy' with the requirement's signature
class MoveOnly {
    pub var n: i32 = 0
    fn MoveOnly(self) { }
    @move fn MoveOnly(self, other: Self) { self.n = other.n }
}

fn main() -> i32 {
    var a: [MoveOnly]
    var b = a.copy()
    return 0
}
