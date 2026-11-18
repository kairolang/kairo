// A `T?` the body knows only by its bounds is not read as its value where
// nothing proved it non-null: the nullness error, as for a concrete `T?`,
// rather than a C++ error in each instance.

interface Source {
    type Item
    fn next(self) -> Self::Item?
}

class <T> Bag {
    pub var last: T
    pub fn Bag(self, z: T) { self.last = z }
    pub fn put(self, v: T) { self.last = v }
}

fn <T> plain(z: T, x: T?) -> T {
    var b = Bag<T>(z)
    b.put(x)
    return b.last
}

fn <T, J impl Source> local(it: J) -> T requires __builtin_is_same<J::Item, T>() {
    var x = it.next()
    var y: T = x
    return y
}

fn main() -> i32 {
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK:      :18:11: error [SC265E]: 'x' may be null here; check it with 'if x?' first
// CHECK:      :24:16: error [SC265E]: 'x' may be null here; check it with 'if x?' first
// CHECK-NOT:  error
