// What a member specialization cannot be (each SC116E, or SC330E for one
// that specializes no method): written in the generic class itself, of a
// pattern other than every instance or one instance, of a virtual method,
// under a `requires` clause, or matching no method of the class.

class <T> G {
    pub var v: i32 = 0
    fn <U> m(self) -> i32 { return 1 }
    fn <> m<i32>(self) -> i32 { return 2 }
    fn <U> r(self) -> i32 requires U impl Named { return 1 }
}

interface Named { fn name(const self) -> i32 }

extend <T> G<*T> {
    fn <> m<u8>(self) -> i32 { return 3 }
}

extend <T> G<T> {
    fn <> r<i32>(self) -> i32 { return 4 }
    fn <> m<i64>(self, x: i32) -> i32 { return 5 }
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK-DAG: member_spec_refused.k:9:{{[0-9]+}}: error [SC116E]: an explicit specialization of 'm' inside a generic type or extension is not supported; specialize a method of a generic class in an extension of it
// CHECK-DAG: member_spec_refused.k:16:{{[0-9]+}}: error [SC116E]: a specialization of 'm' in an extension of a pattern other than every instance (`extend <T> G<T>`) or one instance is not yet supported
// CHECK-DAG: member_spec_refused.k:20:{{[0-9]+}}: error [SC116E]: a specialization of 'r' under a `requires` clause or bounds is not yet supported
// CHECK-DAG: member_spec_refused.k:21:{{[0-9]+}}: error [SC330E]: explicit specialization of 'm' matches no generic method of its class
