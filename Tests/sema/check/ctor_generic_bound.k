// A generic constructor's `impl` bound is checked at the construction call,
// as a generic function's is at its call: an argument that does not conform
// is the error here, not a constraint failure in the emitted C++.

interface Bytes {
    fn data(const self) -> *const u8
    fn size(const self) -> usize
}

class Holder {
    pub var n: i32 = 0
    pub fn <S impl Bytes> Holder(self, const s: S) {
        self.n = s.size() as i32
    }
}

fn main() -> i32 {
    var x: i32 = 3
    var h = Holder(x)
    return h.n
}

// --- lit wiring ---
// RUN: { %kairo --type-check-only %s 2>&1 || true; } | %FileCheck %s
// CHECK: ctor_generic_bound.k:19:13: error [SC162E]: 'i32' does not conform to 'Bytes'
// CHECK: note [I900N]: required by this bound
