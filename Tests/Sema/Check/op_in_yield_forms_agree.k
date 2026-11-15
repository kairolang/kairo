// `op in (self)` and `op in (const self)` may both be declared, and yield
// one form: both a value, both a pointer, or both an unsafe pointer
// (SC299E). The pointee may differ in const: through `const self` a field's
// address is a `*const T`.

class Mixed {
    var a: i32 = 0
    fn op in (self) -> yield *i32 {
        yield &self.a
    }

    fn op in (const self) -> yield i32 {
        yield self.a
    }
}

class Fine {
    var a: i32 = 0
    fn op in (self) -> yield *i32 {
        yield &self.a
    }

    fn op in (const self) -> yield *const i32 {
        yield &self.a
    }

    fn op in (self, x: i32) -> bool {
        return x == self.a
    }
}

fn main() -> i32 {
    var   m = Mixed()
    const c = Mixed()
    var   s = 0
    for x in m {
        s += x
    }

    for x in c {
        s += x
    }

    return s
}

// --- lit wiring ---
// RUN: { %kairo --type-check-only %s 2>&1 || true; } | %FileCheck %s --implicit-check-not=error
// CHECK: op_in_yield_forms_agree.k:12:5: error [SC299E]: 'op in' yields a value ('T') here and a pointer ('*T') in its other form; 'op in (self)' and 'op in (const self)' yield one form
// CHECK-NEXT: op_in_yield_forms_agree.k:8:5: note [SC299N]: the other form is declared here
