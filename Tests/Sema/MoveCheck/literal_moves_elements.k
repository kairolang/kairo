// A named value used as an element of a literal whose elements cannot be
// copied is moved from, and dead afterwards (SC052E), whether the literal
// is a vector, a fixed array or a tuple. A `const` binding cannot be moved
// from: the error names `copy()`, with the fix-it when the type has one.

class M {
    pub var n: i32
    pub fn M(self, n: i32) { self.n = n }
    @move pub fn M(self, other: Self) { self.n = other.n }
}

class C {
    pub var n: i32
    pub fn C(self, n: i32) { self.n = n }
    @move pub fn C(self, other: Self) { self.n = other.n }
    pub fn copy(const self) -> C { return C(self.n) }
}

fn vector() -> i32 {
    var a = M(1)
    var b = M(2)
    var v: [M] = [a, M(3), b]
    return a.n + b.n
}

fn array() -> i32 {
    var a = M(1)
    var xs: [M; 2] = [a, M(2)]
    return a.n
}

fn tuple() -> i32 {
    var a = M(1)
    var t = (a, 1)
    return a.n
}

fn twice() -> i32 {
    var a = M(1)
    var v: [M] = [a, a]
    return 0
}

fn constants() -> i32 {
    const k = M(4)
    var v: [M] = [k]
    const c = C(5)
    var u: [C] = [c]
    var ok: [C] = [c.copy()]
    var t = (k, 2)
    var xs: [M; 1] = [k]
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: literal_moves_elements.k:23:12: error [SC052E]: 'a' is used after being moved
// CHECK: literal_moves_elements.k:22:19: note [I900N]: 'a' was moved here, into the vector literal
// CHECK: literal_moves_elements.k:23:18: error [SC052E]: 'b' is used after being moved
// CHECK: literal_moves_elements.k:22:28: note [I900N]: 'b' was moved here, into the vector literal
// CHECK: literal_moves_elements.k:29:12: error [SC052E]: 'a' is used after being moved
// CHECK: literal_moves_elements.k:28:23: note [I900N]: 'a' was moved here, into the array
// CHECK: literal_moves_elements.k:35:12: error [SC052E]: 'a' is used after being moved
// CHECK: literal_moves_elements.k:34:14: note [I900N]: 'a' was moved here, into the tuple
// CHECK: literal_moves_elements.k:40:22: error [SC052E]: 'a' is used after being moved
// CHECK: literal_moves_elements.k:40:19: note [I900N]: 'a' was moved here, into the vector literal
// CHECK: literal_moves_elements.k:46:19: error [SC182E]: 'k' is const, so it cannot be moved into the vector literal, and a 'M' is never copied implicitly: only an explicit copy, 'k.copy()', can be an element here
// CHECK: literal_moves_elements.k:46:19: note [I900N]: 'M' declares no public 'fn copy(const self) -> Self'
// CHECK: literal_moves_elements.k:45:5: note [I900N]: declared const here
// CHECK: literal_moves_elements.k:48:19: error [SC182E]: 'c' is const, so it cannot be moved into the vector literal, and a 'C' is never copied implicitly: only an explicit copy, 'c.copy()', can be an element here
// CHECK: literal_moves_elements.k:48:20: note [I900N]: 'C' has a 'copy' method: write 'c.copy()' to put a copy of 'c' in the vector literal
// CHECK: fix-it:{{.*}}:{48:20-48:20}:".copy()"
// CHECK: literal_moves_elements.k:50:14: error [SC182E]: 'k' is const, so it cannot be moved into the tuple
// CHECK: literal_moves_elements.k:51:23: error [SC182E]: 'k' is const, so it cannot be moved into the array
