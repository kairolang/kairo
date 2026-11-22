// `[T]`'s `copy` is declared in `extend <T impl Copyable> Vector<T>`, so a
// vector of a move-only element has no `copy` at all. The Copyable error
// says so and names the element that misses the bound, at the bound; it
// does not call the extension's `copy` one of another shape.

class Mv {
    pub var n: i32

    pub fn Mv(self, n: i32) {
        self.n = n
    }

    @move pub fn Mv(self, other: Self) {
        self.n = other.n
    }
}

fn <T impl Copyable> dup(const x: T) -> T {
    return x.copy()
}

fn elements(const v: [Mv]) {
    var w = dup(v)
    // CHECK: [[@LINE-1]]:13: error [SC162E]: '[Mv]' does not conform to 'Copyable': no member 'copy' with the requirement's signature
    // CHECK: note [I900N]: required by this bound
    // CHECK: note [I900N]: 'copy' is required here
    // CHECK: [[@LINE-4]]:13: note [I900N]: '[Mv]' is not a COPY type, and its 'copy' is declared only where 'Mv impl Copyable'
    // CHECK: vector.k:{{[0-9]+}}:{{[0-9]+}}: note [I900N]: '[Mv]' has 'copy' only where 'Mv impl Copyable': 'Mv' does not conform to 'Copyable'
}

fn nested(const v: [[Mv]]) {
    var w = dup(v)
    // CHECK: [[@LINE-1]]:13: error [SC162E]: '{{\[\[}}Mv]]' does not conform to 'Copyable': no member 'copy' with the requirement's signature
    // CHECK: note [I900N]: '{{\[\[}}Mv]]' is not a COPY type, and its 'copy' is declared only where '[Mv] impl Copyable'
    // CHECK: note [I900N]: '{{\[\[}}Mv]]' has 'copy' only where '[Mv] impl Copyable': '[Mv]' does not conform to 'Copyable'
}

// --- lit wiring -----------------------------------------------------------
// RUN: %overlay_builtins %t.lib base/copy.k=%S/inputs/copy.k
// RUN: { %kairo_overlay --builtins-dir=%t.lib/builtin %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="declares this 'copy'"
