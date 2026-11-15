ffi "c++" import "Inputs/plain.h"

class Bag {
    pub var n: i32 = 3
    fn Bag(self) = default
}

class Counted {
    pub var n: i32 = 4
    fn Counted(self) = default
    fn count(const self) -> i32 {
        return self.n
    }
}

fn main() -> i32 {
    var c = Counted()
    var k = count_of(c)
    var b = Bag()
    return k + count_of(b)
}

// --- lit wiring ---
// A C++ template that uses a member the Kairo class lacks: one Kairo-placed
// error at the call, clang's reason, its place in the header as a note.
// RUN: rm -rf %t.d
// RUN: { %kairo %s -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="in instantiation of"
//
// CHECK: missing_member.k:20:16: error [CL002E]: instantiating function template specialization 'count_of<missing_member::Bag>' here does not compile in C++: no member named 'count' in 'missing_member::Bag'
// CHECK-NEXT: plain.h:3:{{[0-9]+}}: note [I900N]: the C++ error is here, in the template's body
