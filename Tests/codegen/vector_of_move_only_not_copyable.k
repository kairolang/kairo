// RUN: rm -rf %t.d
// RUN: { %kairo %s -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s
// Loosening Vector's copy constraint for a class still being defined
// must not make a vector of a COMPLETE move-only element copyable.
// Kairo reports it itself, before clang sees it.
// CHECK: error [SC182E]: cannot copy a value of type '[MoveOnly]': copying it copies each 'MoveOnly', and 'MoveOnly' cannot be copied
class MoveOnly {
    pub var n: i32 = 0
    fn MoveOnly(self) { }
    @move fn MoveOnly(self, other: Self) { self.n = other.n }
}

fn main() -> i32 {
    var a: [MoveOnly]
    var b = a
    return 0
}
