// A declared `impl` on a redeclared record is one conformance and is
// reported once. P names Shape on its forward declaration and on its
// definition: one error, at the definition's clause, with the stub fix-it
// before the definition's closing brace. R names Shape only on its forward
// declaration: one error there, with no fix-it, since that declaration has
// no body to insert into. Q meets Shape: no error.

interface Shape {
    fn area(const self) -> i32
}

class P impl Shape
class P impl Shape { pub var x: i32 = 0 }

class Q impl Shape
class Q impl Shape {
    pub var x: i32 = 0
    pub fn area(const self) -> i32 { return self.x }
}

class R impl Shape
class R {
    pub var x: i32 = 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="fix-it:"
// CHECK: impl_declared_redeclared.k:13:14: error [SC162E]: 'P' declares 'impl Shape' but does not conform to it: it has no 'area' with the requirement's signature
// CHECK-NEXT: fix-it:"{{.*}}impl_declared_redeclared.k":{13:41-13:41}:"    pub fn area(const self) -> i32 { }\n"
// CHECK-NEXT: impl_declared_redeclared.k:9:5: note [I900N]: 'area' is required here
// CHECK: impl_declared_redeclared.k:21:14: error [SC162E]: 'R' declares 'impl Shape' but does not conform to it: it has no 'area' with the requirement's signature
// CHECK-NEXT: impl_declared_redeclared.k:9:5: note [I900N]: 'area' is required here
