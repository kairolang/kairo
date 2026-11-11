// RUN: rm -rf %t.d
// RUN: { %kairo %s -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s
// P796 guard: loosening Vector's copy constraint for a class still being defined
// must not make a vector of a COMPLETE move-only element copyable.
// CHECK: error [CL001E]: no matching constructor for initialization of {{.*}}Vector<{{.*}}MoveOnly>
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
