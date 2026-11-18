// A vector literal of elements that cannot be copied is built in place.
// Where it is the whole initializer of a local `var` it fills that
// variable. Anywhere else the vector itself is moved out of the expression
// that builds it, which needs a vector that can be moved: `[M]` declares a
// copy constructor only, and that one needs a copyable element, so each of
// these is refused here and never reaches clang. A set or a map adds
// through `insert`, which takes its operands `const` and copies them, so
// such a literal is refused wherever it stands.

class M {
    pub var n: i32
    pub fn M(self, n: i32) { self.n = n }
    @move pub fn M(self, other: Self) { self.n = other.n }
    pub fn hash(const self) -> usize { return self.n as usize }
    pub fn op == (const self, const o: M) -> bool { return self.n == o.n }
}

struct Holder {
    var items: [M]
}

fn take(const v: [M]) -> usize { return v.size() }

fn make() -> [M] {
    return [M(1), M(2)]
}

fn main() -> i32 {
    var ok: [M] = [M(1)]
    var n = take([M(1)])
    var nested: [[M]] = [[M(1)], [M(2)]]
    const fixed: [M] = [M(1)]
    var h = Holder{items: [M(1)]}
    var s: {M} = {M(1)}
    var m: {i32: M} = {1: M(1)}
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: literal_container_transfer.k:25:12: error [SC182E]: a vector literal of elements that cannot be copied is built in place, so here it can only initialize a 'var' of type '[M]': '[M]' cannot be moved out of the expression, and it cannot be copied (copying it copies each 'M', and 'M' cannot be copied)
// CHECK: literal_container_transfer.k:25:12: note [I900N]: declare a 'var' of type '[M]' with this literal as its whole initializer, and use the variable here
// CHECK: literal_container_transfer.k:30:18: error [SC182E]: a vector literal of elements that cannot be copied is built in place
// CHECK: literal_container_transfer.k:31:26: error [SC182E]: a vector literal of elements that cannot be copied is built in place
// CHECK: literal_container_transfer.k:31:34: error [SC182E]: a vector literal of elements that cannot be copied is built in place
// CHECK: literal_container_transfer.k:32:24: error [SC182E]: a vector literal of elements that cannot be copied is built in place
// CHECK: literal_container_transfer.k:33:27: error [SC182E]: a vector literal of elements that cannot be copied is built in place
// CHECK: literal_container_transfer.k:34:18: error [SC182E]: a set literal of 'M' elements cannot be built yet: the set copies each element out of the literal, and 'M' cannot be copied (it declares a move constructor and no copy constructor)
// CHECK: literal_container_transfer.k:35:23: error [SC182E]: a map literal of 'M' elements cannot be built yet: the map copies each element out of the literal, and 'M' cannot be copied (it declares a move constructor and no copy constructor)
