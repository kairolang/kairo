// The rule belongs to the lang item, the `Copyable` the builtin tree
// declares, not to the name: an interface a program declares under that
// name is met only by a type with a `copy` of its own.

interface Copyable {
    fn copy(const self) -> Self
}

class Has {
    pub var n: i32

    pub fn Has(self, n: i32) {
        self.n = n
    }

    pub fn copy(const self) -> Self {
        return Has(self.n)
    }
}

struct Plain {
    var n: i32
}

fn <T impl Copyable> dup(const x: T) -> T {
    return x.copy()
}

fn main() -> i32 {
    var h = dup(Has(3))
    var p = dup(Plain { n: 1 })
    // CHECK: [[@LINE-1]]:13: error [SC162E]: 'Plain' does not conform to 'Copyable': no member 'copy' with the requirement's signature
    var i = dup(5)
    // CHECK: [[@LINE-1]]:13: error [SC162E]: 'i32' does not conform to 'Copyable': no member 'copy' with the requirement's signature
    // CHECK-NOT: is not a COPY type
    return h.n
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// RUN: %overlay_builtins %t.lib base/copy.k=%S/inputs/copy.k
// RUN: { %kairo_overlay --builtins-dir=%t.lib/builtin %s --type-check-only 2>&1 || true; } | %FileCheck %s
