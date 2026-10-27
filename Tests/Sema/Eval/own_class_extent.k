eval fn two() -> i32 { return 2 }

pub class Box {
    pub eval K: i32 = 3
    pub eval J: i32 = two()
    pub var a: [i32; K]
    pub var b: [i32; J]
    fn Box(self) { }
}

fn main() -> i32 {
    var outside: [i32; Box::K] = [1, 2, 3]
    return outside[2]
}

// EVAL.md 1.2a: `[i32; J]` as a field of J's own class, where J's value is
// C++'s to compute (it calls an eval fn): inside its own body the class is
// incomplete, and C++ cannot read J there. SC116E, a note at J, and a
// fix-it moving J (with its `pub`) to module scope. K folds, so its extent
// is the number and needs no C++ constant: accepted, in the class and out.
// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: own_class_extent.k:7:22: error [SC116E]: an array length computed by C++ from 'J', an 'eval' constant of the field's own class, is not supported: 'Box' is incomplete inside its own body
// CHECK-NEXT: fix-it:"{{.*}}own_class_extent.k":{3:1-3:1}:"eval J: i32 = two()\n"
// CHECK-NEXT: fix-it:"{{.*}}own_class_extent.k":{5:5-5:28}:""
// CHECK-NEXT: own_class_extent.k:5:14: note [SC001N]: 'J' is declared here; its value is computed by C++, which reads it only once the class is complete
