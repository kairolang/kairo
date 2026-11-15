// A specialization of m<i32> for every instance and one of every m for
// G<u8> both apply to G<u8>.m<i32>, and neither is more specialized: an
// error naming both (SC333E), until that combination is written itself.

class <T> G {
    fn <U> m(self) -> i32 { return 1 }
}

extend <T> G<T> {
    fn <> m<i32>(self) -> i32 { return 2 }
}

extend G<u8> {
    fn <U> m(self) -> i32 { return 3 }
}

fn main() -> i32 {
    var b = G<u8>()
    return b.m<i32>()
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.d
// RUN: { %kairo %s -c -o %t.o --cache-dir %t.d 2>&1 || true; } | %FileCheck %s
// CHECK: member_spec_overlap.k:14:{{[0-9]+}}: error [SC333E]: two specializations of 'm' both apply to one instance and argument list
// CHECK: member_spec_overlap.k:10:{{[0-9]+}}: note [SC333N]: the other specialization is here
