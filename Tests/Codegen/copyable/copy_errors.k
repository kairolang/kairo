// What does not meet the Copyable lang item: a move-only type with no
// `copy` (the error names the method to declare), an array (it is no
// value), and a COPY type whose own `copy` has another shape (the method
// is the type's `copy`, so the copy constructor does not stand in for it).
// `x.copy()` on the first two is the same error at the call; on the third
// it is the method, called with the wrong arguments.

class Mv {
    pub var n: i32

    pub fn Mv(self, n: i32) {
        self.n = n
    }

    @move pub fn Mv(self, other: Self) {
        self.n = other.n
    }
}

class Odd {
    pub var n: i32

    pub fn Odd(self, n: i32) {
        self.n = n
    }

    pub fn copy(const self, by: i32) -> i32 {
        return self.n + by
    }
}

class <T> Cell {
    pub var v: T

    pub fn Cell(self, v: T) {
        self.v = v
    }
}

class <T impl Copyable> Tag {
    pub var n: i32

    pub fn Tag(self) {
        self.n = 1
    }
}

fn <T impl Copyable> dup(const x: T) -> T {
    return x.copy()
}

fn bound(const m: Mv, const o: Odd, const c: Cell<Mv>) {
    var a = dup(m)
    // CHECK: [[@LINE-1]]:13: error [SC162E]: 'Mv' does not conform to 'Copyable': no member 'copy' with the requirement's signature
    // CHECK: note [I900N]: required by this bound
    // CHECK: note [I900N]: 'copy' is required here
    // CHECK: note [I900N]: 'Mv' is not a COPY type, so it has no implicit 'copy': declare 'fn copy(const self) -> Self' on it
    var b = dup(o)
    // CHECK: [[@LINE-1]]:13: error [SC162E]: 'Odd' does not conform to 'Copyable': no member 'copy' with the requirement's signature
    // CHECK: note [I900N]: 'Odd' declares this 'copy', so its copy constructor does not stand in for one: 'Copyable' needs 'fn copy(const self) -> Self'
    var d = dup(c)
    // CHECK: [[@LINE-1]]:13: error [SC162E]: 'Cell<Mv>' does not conform to 'Copyable': no member 'copy' with the requirement's signature
    // CHECK: note [I900N]: 'Cell<Mv>' is not a COPY type
    var e = copy(m)
    // CHECK: [[@LINE-1]]:13: error [SC162E]: 'Mv' does not conform to 'Copyable'
}

// A vector's copy constructor needs its element's: `[Mv]` has none.
fn elements(const v: [Mv]) {
    var w = dup(v)
    // CHECK: [[@LINE-1]]:13: error [SC162E]: '[Mv]' does not conform to 'Copyable': no member 'copy' with the requirement's signature
    // CHECK: note [I900N]: '[Mv]' is not a COPY type
    // CHECK: note [I900N]: '[Mv]' declares a copy constructor, but its requirements do not hold here: 'Mv' cannot be copied
}

// `copy` is called: with no method behind it there is nothing to name.
fn value(i: i32) {
    var f = i.copy
    // CHECK: [[@LINE-1]]:13: error [SC001E]: 'copy' on a 'i32' is its copy constructor, which is not a value; call it, as 'x.copy()'
}

fn member(const m: Mv, const o: Odd) {
    var a = m.copy()
    // CHECK: [[@LINE-1]]:13: error [SC162E]: 'Mv' does not conform to 'Copyable': no member 'copy' with the requirement's signature
    // CHECK: note [I900N]: 'Mv' is not a COPY type, so it has no implicit 'copy': declare 'fn copy(const self) -> Self' on it
    var b = o.copy()
    // CHECK: [[@LINE-1]]:13: error [SC021E]: missing argument for parameter 'by'
}

fn arrays() {
    var arr: [i32; 3] = [1, 2, 3]
    var a = dup(arr)
    // CHECK: [[@LINE-1]]:13: error [SC083E]: an array is not copyable
    var b = arr.copy()
    // CHECK: [[@LINE-1]]:13: error [SC083E]: an array is not copyable
    var t = Tag<[i32; 3]>()
    // CHECK: [[@LINE-1]]:13: error [SC162E]: '[i32; 3]' does not conform to 'Copyable': no member 'copy' with the requirement's signature
    // CHECK: note [I900N]: an array is not copyable: view it through a slice, or copy its elements
}

// --- lit wiring -----------------------------------------------------------
// RUN: %overlay_builtins %t.lib base/copy.k=%S/Inputs/copy.k
// RUN: { %kairo_overlay --builtins-dir=%t.lib/builtin %s --type-check-only 2>&1 || true; } | %FileCheck %s
