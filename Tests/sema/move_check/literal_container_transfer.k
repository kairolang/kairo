// A vector, set or map literal of elements that cannot be copied is built
// in place and moved where it goes: the whole initializer of a local, a
// by-value or const argument, a return value, an element of another
// literal, a const binding, a field initializer. Each container moves its
// elements in, so none of these needs a copy.

class M {
    pub var n: i32
    pub fn M(self, n: i32) { self.n = n }
    @move pub fn M(self, other: Self) { self.n = other.n }
    pub fn hash(const self, @inout h: Hasher) { h.write_usize(self.n as usize) }
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
    return (make().size() + n + nested.size() + fixed.size() + h.items.size() + s.size() + m.size() + ok.size()) as i32
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
// CHECK-NOT: error
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 10
