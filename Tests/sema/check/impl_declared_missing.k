// A declared `impl I` that does not hold is an error at the `impl` clause
// (classes.mdx, Interfaces: the `impl` keyword triggers the check at the
// declaration site), whether or not anything uses the type through `I`.
// The error names every missing requirement, with a note at each one's
// declaration in the interface, and a fix-it adding a stub for each
// missing method that has no member of its name. A member of the name but
// another signature gets a note instead of a stub.

interface Shape {
    fn area(const self) -> i32
    fn name(const self) -> string
}

interface Equal {
    fn op ==(const self, const o: Self) -> bool
}

interface Make {
    static fn make() -> Self
}

interface Named {
    fn label(const self) -> string
}

interface Tagged derives Named {
    fn tag(const self) -> i32
}

class Empty impl Shape {
    pub var a: i32 = 0
}

class Wrong impl Shape {
    pub fn area(const self) -> i64 { return 0 }
    pub fn name(const self) -> string { return "w" }
}

class NoEq impl Equal {
    pub var v: i32 = 0
}

class NoMake impl Make {
    pub var v: i32 = 0
}

class OnlyTag impl Tagged {
    pub fn tag(const self) -> i32 { return 1 }
}

struct Point {
    pub var x: i32
}

extend Point impl Shape {
    pub fn area(const self) -> i32 { return self.x }
}

enum Color { Red, Green }

extend Color impl Named {
}

class Key impl Hash {
    pub var a: i32 = 0
}

fn main() -> i32 {
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: impl_declared_missing.k:30:18: error [SC162E]: 'Empty' declares 'impl Shape' but does not conform to it: it has no 'area', 'name' with the requirements' signatures
// CHECK-NEXT: fix-it:"{{.*}}impl_declared_missing.k":{32:1-32:1}:"    pub fn area(const self) -> i32 { }\n    pub fn name(const self) -> string { }\n"
// CHECK-NEXT: impl_declared_missing.k:10:5: note [I900N]: 'area' is required here
// CHECK-NEXT: impl_declared_missing.k:11:5: note [I900N]: 'name' is required here
// CHECK: impl_declared_missing.k:34:18: error [SC162E]: 'Wrong' declares 'impl Shape' but does not conform to it: it has no 'area' with the requirement's signature
// CHECK-NEXT: impl_declared_missing.k:10:5: note [I900N]: 'area' is required here
// CHECK-NEXT: impl_declared_missing.k:35:12: note [I900N]: 'area' is declared here, with a signature other than the requirement's
// CHECK: impl_declared_missing.k:39:17: error [SC162E]: 'NoEq' declares 'impl Equal' but does not conform to it: it has no 'op ==' with the requirement's signature
// CHECK-NEXT: fix-it:"{{.*}}impl_declared_missing.k":{41:1-41:1}:"    pub fn op ==(const self, const o: NoEq) -> bool { }\n"
// CHECK-NEXT: impl_declared_missing.k:15:5: note [I900N]: 'op ==' is required here
// CHECK: impl_declared_missing.k:43:19: error [SC162E]: 'NoMake' declares 'impl Make' but does not conform to it: it has no 'make' with the requirement's signature
// CHECK-NEXT: fix-it:"{{.*}}impl_declared_missing.k":{45:1-45:1}:"    pub static fn make() -> NoMake { }\n"
// CHECK-NEXT: impl_declared_missing.k:19:5: note [I900N]: 'make' is required here
// CHECK: impl_declared_missing.k:47:20: error [SC162E]: 'OnlyTag' declares 'impl Tagged' but does not conform to it: it has no 'label' with the requirement's signature
// CHECK-NEXT: fix-it:"{{.*}}impl_declared_missing.k":{49:1-49:1}:"    pub fn label(const self) -> string { }\n"
// CHECK-NEXT: impl_declared_missing.k:23:5: note [I900N]: 'label' is required here, by 'Named', which 'Tagged' derives
// CHECK: impl_declared_missing.k:55:19: error [SC162E]: 'Point' declares 'impl Shape' but does not conform to it: it has no 'name' with the requirement's signature
// CHECK-NEXT: fix-it:"{{.*}}impl_declared_missing.k":{57:1-57:1}:"    pub fn name(const self) -> string { }\n"
// CHECK-NEXT: impl_declared_missing.k:11:5: note [I900N]: 'name' is required here
// CHECK: impl_declared_missing.k:61:19: error [SC162E]: 'Color' declares 'impl Named' but does not conform to it: it has no 'label' with the requirement's signature
// CHECK-NEXT: fix-it:"{{.*}}impl_declared_missing.k":{62:1-62:1}:"    pub fn label(const self) -> string { }\n"
// CHECK-NEXT: impl_declared_missing.k:23:5: note [I900N]: 'label' is required here
// CHECK: impl_declared_missing.k:64:16: error [SC162E]: 'Key' declares 'impl Hash' but does not conform to it: it has no 'op ==', 'hash' with the requirements' signatures
// CHECK-NEXT: fix-it:"{{.*}}impl_declared_missing.k":{66:1-66:1}:"    pub fn op ==(const self, const o: Key) -> bool { }\n    pub fn hash(const self, @inout h: Hasher) { }\n"
// CHECK-NEXT: cmp.k:{{[0-9]+}}:{{[0-9]+}}: note [I900N]: 'op ==' is required here, by 'Eq', which 'Hash' derives
// CHECK-NEXT: hash.k:{{[0-9]+}}:{{[0-9]+}}: note [I900N]: 'hash' is required here
