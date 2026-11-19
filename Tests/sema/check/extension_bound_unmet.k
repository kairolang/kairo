// A member of a generic extension called on a receiver whose argument does
// not meet the extension's bound is an error at the call, naming the bound:
// a parameter-list bound and a requires clause alike, and an enum with no
// `hash` against the Hash lang item.

interface Named {
    fn name(const self) -> i32
}

class <K> Box {
    pub var k: K

    pub fn Box(self, k: K) {
        self.k = k
    }
}

extend <K impl Named> Box<K> {
    fn label(const self) -> i32 {
        return self.k.name()
    }
}

extend <K> Box<K> requires K impl Named {
    fn label2(const self) -> i32 {
        return self.k.name()
    }
}

extend <K impl Hash> Box<K> {
    fn same(const self, const o: K) -> bool {
        return self.k == o
    }
}

enum E { A, B }

fn main() -> i32 {
    var b = Box<i32>(3)
    var e = Box<E>(E::A)
    return b.label() + b.label2() + (if (e.same(E::B)) => 1 else => 0)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: extension_bound_unmet.k:41:12: error [SC162E]: 'i32' does not conform to 'Named': no member 'name' with the requirement's signature
// CHECK: extension_bound_unmet.k:18:9: note [I900N]: required by this bound
// CHECK: extension_bound_unmet.k:41:24: error [SC162E]: 'i32' does not conform to 'Named': no member 'name' with the requirement's signature
// CHECK: extension_bound_unmet.k:24:28: note [I900N]: required by this bound
// CHECK: extension_bound_unmet.k:41:42: error [SC162E]: 'E' does not conform to 'Hash': no member 'op ==' with the requirement's signature
// CHECK: extension_bound_unmet.k:30:9: note [I900N]: required by this bound
