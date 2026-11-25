// A loop binder whose type cannot be copied is refused (SC182E), and its
// note names the pointer binder the loop takes instead. Where `op in`
// yields the element read-only (through `op in (const self)` on a const
// iterable or a type with no other form, or as a `*const T`: a const vector,
// a set, a map's key) that binder is `const *x`, since the binder rule
// refuses `*x` there (SC298E). Over a mutable vector or a mutable record with
// `op in (self) -> yield *T` it is `*x`. Over a value yield the note names
// the yield to declare: `*const T` where a `*x` binder would keep the loop
// on `op in (const self)`. The loops in `pointers` check that each suggested
// binder is accepted.

class M {
    pub var v: i32 = 0
    fn M(self, v: i32) { self.v = v }
    @move fn M(self, other: Self) { self.v = other.v }
    pub fn op ==(const self, const o: Self) -> bool { return self.v == o.v }
    pub fn hash(const self, @inout h: Hasher) { }
}

class Ro {
    var m: M = M(1)
    fn op in (const self) -> yield *const M { yield &self.m }
}

class Box {
    var m: M = M(1)
    fn op in (self) -> yield *M { yield &self.m }
    fn op in (const self) -> yield *const M { yield &self.m }
}

class Vo {
    var m: i32 = 1
    fn op in (const self) -> yield M { yield M(self.m) }
}

class Vb {
    var m: i32 = 1
    fn op in (self) -> yield M { yield M(self.m) }
    fn op in (const self) -> yield M { yield M(self.m) }
}

fn copies(const cv: [M], st: {M}, r: Ro, const cb: Box, mv: [M], b: Box) -> i32 {
    var n = 0
    for x: M in cv { n += x.v }
    for x: M in st { n += x.v }
    for x: M in r { n += x.v }
    for x: M in cb { n += x.v }
    for x: M in mv { n += x.v }
    for x: M in b { n += x.v }
    return n
}

fn parts(mp: {M: M}, const ps: [(M, i32)]) -> i32 {
    var n = 0
    for (k: M, v) in mp { n += k.v + v.v }
    for (a: M, c) in ps { n += a.v + c }
    return n
}

fn values(vo: Vo, const cvb: Vb, vb: Vb) -> i32 {
    var n = 0
    for x: M in vo { n += x.v }
    for x: M in cvb { n += x.v }
    for x: M in vb { n += x.v }
    return n
}

fn pointers(const cv: [M], st: {M}, r: Ro, const cb: Box, mv: [M], b: Box,
            mp: {M: M}, const ps: [(M, i32)]) -> i32 {
    var n = 0
    for const *x in cv { n += x->v }
    for const *x in st { n += x->v }
    for const *x in r { n += x->v }
    for const *x in cb { n += x->v }
    for *x in mv { n += x->v }
    for *x in b { n += x->v }
    for (const *k, *v) in mp { n += k->v + v->v }
    for (const *a, c) in ps { n += a->v + c }
    return n
}

fn main() -> i32 { return 0 }

// --- lit wiring ---
// RUN: { %kairo --type-check-only %s 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: binder_copy_readonly_pointer_note.k:44:9: error [SC182E]: cannot copy a value of type 'M'
// CHECK-NEXT: binder_copy_readonly_pointer_note.k:44:9: note [I900N]: the loop binder 'x' is a copy of each element; bind 'const *x' for a pointer to it instead
// CHECK: binder_copy_readonly_pointer_note.k:45:9: error [SC182E]: cannot copy a value of type 'M'
// CHECK-NEXT: binder_copy_readonly_pointer_note.k:45:9: note [I900N]: the loop binder 'x' is a copy of each element; bind 'const *x' for a pointer to it instead
// CHECK: binder_copy_readonly_pointer_note.k:46:9: error [SC182E]: cannot copy a value of type 'M'
// CHECK-NEXT: binder_copy_readonly_pointer_note.k:46:9: note [I900N]: the loop binder 'x' is a copy of each element; bind 'const *x' for a pointer to it instead
// CHECK: binder_copy_readonly_pointer_note.k:47:9: error [SC182E]: cannot copy a value of type 'M'
// CHECK-NEXT: binder_copy_readonly_pointer_note.k:47:9: note [I900N]: the loop binder 'x' is a copy of each element; bind 'const *x' for a pointer to it instead
// CHECK: binder_copy_readonly_pointer_note.k:48:9: error [SC182E]: cannot copy a value of type 'M'
// CHECK-NEXT: binder_copy_readonly_pointer_note.k:48:9: note [I900N]: the loop binder 'x' is a copy of each element; bind '*x' for the element's address instead
// CHECK: binder_copy_readonly_pointer_note.k:49:9: error [SC182E]: cannot copy a value of type 'M'
// CHECK-NEXT: binder_copy_readonly_pointer_note.k:49:9: note [I900N]: the loop binder 'x' is a copy of each element; bind '*x' for the element's address instead
// CHECK: binder_copy_readonly_pointer_note.k:55:10: error [SC182E]: cannot copy a value of type 'M'
// CHECK-NEXT: binder_copy_readonly_pointer_note.k:55:10: note [I900N]: the loop binder 'k' is a copy of its part of each element; bind 'const *k' for a pointer to it instead
// CHECK: binder_copy_readonly_pointer_note.k:56:10: error [SC182E]: cannot copy a value of type 'M'
// CHECK-NEXT: binder_copy_readonly_pointer_note.k:56:10: note [I900N]: the loop binder 'a' is a copy of its part of each element; bind 'const *a' for a pointer to it instead
// CHECK: binder_copy_readonly_pointer_note.k:62:9: error [SC182E]: cannot copy a value of type 'M'
// CHECK-NEXT: binder_copy_readonly_pointer_note.k:62:9: note [I900N]: the loop binder 'x' is a copy of each element; its 'op in' yields values; declare it '-> yield *const M' and bind 'const *x' for the element's address
// CHECK: binder_copy_readonly_pointer_note.k:63:9: error [SC182E]: cannot copy a value of type 'M'
// CHECK-NEXT: binder_copy_readonly_pointer_note.k:63:9: note [I900N]: the loop binder 'x' is a copy of each element; its 'op in' yields values; declare it '-> yield *const M' and bind 'const *x' for the element's address
// CHECK: binder_copy_readonly_pointer_note.k:64:9: error [SC182E]: cannot copy a value of type 'M'
// CHECK-NEXT: binder_copy_readonly_pointer_note.k:64:9: note [I900N]: the loop binder 'x' is a copy of each element; its 'op in' yields values; declare it '-> yield *M' and bind '*x' for the element's address
