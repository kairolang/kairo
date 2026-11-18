// Kairo permits no const overloading except on a place operator: `op +`
// beside `op +(const self, ...)` is one member declared twice (R041E), and
// the `op []` pair beside it is two entities (RedeclMerge._same_signature).
// Its own file: R041E is a resolution error, and the rule checks in rules.k
// run only on a tree that resolved.

struct V {
    var x: i32
    var buf: [i32; 2]
    fn op +(self, o: V) -> V { return V{ x: self.x + o.x, buf: [0, 0] } }
    fn op +(const self, o: V) -> V { return o }
    fn op [](self, i: usize) -> *i32 { return &self.buf[i] }
    fn op [](const self, i: usize) -> *const i32 { return &self.buf[i] }
    fn op l++(self) -> V { return V{ x: self.x + 1, buf: [0, 0] } }
    fn op r++(self) -> V { return V{ x: self.x, buf: [0, 0] } }
}

// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG: const_overload.k:11:5: error [R041E]: class member '{{.*}}' cannot be redeclared
// DIAG-NEXT: const_overload.k:10:5: note [R041N]: previous declaration is here
// DIAG-NOT: error
