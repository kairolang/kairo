// An out-of-line definition writes no visibility keyword: the member takes
// the visibility of its in-class declaration (classes-out-of-line.mdx,
// Rules), so a keyword on the definition is R071E, the same one or
// another, with a fix-it that removes it. The declaration still decides:
// `quiet` stays private and `loud` public.

class Dial {
    pub var v: i32 = 0
    pub fn loud(self) -> i32
    priv fn quiet(self) -> i32
    fn plain(self) -> i32
    pub static fn zero() -> i32
    pub fn op -(self, other: Dial) -> i32
}

pub fn Dial::loud(self) -> i32 { return self.v }
pub fn Dial::quiet(self) -> i32 { return 1 }
priv fn Dial::plain(self) -> i32 { return 2 }
prot static fn Dial::zero() -> i32 { return 0 }
pub fn Dial::op -(self, other: Dial) -> i32 { return self.v - other.v }

fn main() -> i32 {
    var d = Dial()
    return d.loud() + d.quiet() + d.plain() + Dial::zero() + (d - d)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: {{.*}}:16:1: error [R071E]: a visibility keyword cannot be written on the out-of-line definition of 'loud'; it takes the visibility of its in-class declaration
// CHECK-NEXT: fix-it:"{{.*}}":{16:1-16:4}:""
// CHECK-NEXT: {{.*}}:9:9: note [R071N]: the in-class declaration, where the visibility goes
// CHECK: {{.*}}:17:1: error [R071E]: a visibility keyword cannot be written on the out-of-line definition of 'quiet'
// CHECK: {{.*}}:10:10: note [R071N]: the in-class declaration, where the visibility goes
// CHECK: {{.*}}:18:1: error [R071E]: a visibility keyword cannot be written on the out-of-line definition of 'plain'
// CHECK: {{.*}}:19:1: error [R071E]: a visibility keyword cannot be written on the out-of-line definition of 'zero'
// CHECK: {{.*}}:20:1: error [R071E]: a visibility keyword cannot be written on the out-of-line definition of 'op -'
