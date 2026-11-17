// `.copy()` through a copy constructor needs a concrete type. On a type
// that depends on a type parameter it is refused where it is written, and
// the free `copy`, whose bound each instance checks, is what to write.
class <T> Wrap {
    pub var v: T

    pub fn Wrap(self, v: T) {
        self.v = v
    }

    pub fn twin(const self) -> Self {
        return self.copy()
        // CHECK: [[@LINE-1]]:21: error [R025E]: no member named 'copy' in 'Wrap<T>': '.copy()' through a copy constructor is not available on a type that depends on a type parameter; write 'copy(x)', whose bound each instance checks
    }
}

fn <T> again(p: *T) -> *T {
    return p.copy()
    // CHECK: [[@LINE-1]]:14: error [R025E]: no member named 'copy' in '*T': '.copy()' through a copy constructor is not available
}

// --- lit wiring -----------------------------------------------------------
// RUN: %overlay_builtins %t.lib base/copy.k=%S/Inputs/copy.k
// RUN: { %kairo_overlay --builtins-dir=%t.lib/builtin %s --type-check-only 2>&1 || true; } | %FileCheck %s
