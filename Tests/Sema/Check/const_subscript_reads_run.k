// With a const container's `op []` chosen by its constness, the
// reads stay legal: through the `const self` overload, a const array or
// vector element, `&cb[i]` as a `*const T`, a `for` over a const container,
// and a mutable container's writes. Exit code is the sum of what was read.

class Buf {
    var a: [i32; 4]
    fn op [] (self, i: usize) -> *i32 { return &self.a[i] }
    fn op [] (const self, i: usize) -> *const i32 { return &self.a[i] }
}

// The two forms answer differently, so the exit code shows which one ran on
// a const and on a mutable object.
class Tag {
    fn op [] (self, i: usize) -> i32 { return 100 }
    fn op [] (const self, i: usize) -> i32 { return 1 }
}

fn through_param(const t: Tag) -> i32 {
    return t[0]
}

class Holder {
    var t: Tag
    fn read(const self) -> i32 { return self.t[0] }
}

fn sum(const v: [i32], const a: [i32; 3]) -> i32 {
    var t: i32 = 0
    for e in v { t += e }
    for *e in a { t += *e }
    return t + v[0] + a[2]
}

fn main() -> i32 {
    var b = Buf()
    b[0] = 3
    b[1] += 4
    const cb = b
    var p: *const i32 = &cb[1]
    const ct = Tag()
    var mt = Tag()
    const v: [i32] = [1, 2]
    const a: [i32; 3] = [1, 1, 1]
    const h = Holder()
    // 3 + 4 + 1 + 100 + (1 + 2 + 3 + 1 + 1) + 1 + 1 = 118
    return cb[0] + *p + ct[0] + mt[0] + sum(v, a) + through_param(mt) + h.read()
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 118
