// member_template_of_class_template.k -- exit 11
// A member template of a CLASS TEMPLATE, called on an instance:
// `Box<i32>::pick<i64>`. The registry entry holds only the member's own
// arguments, so the explicit instantiation EmitPlan wrote for it named
// `::m::Box::pick<long>`, a class template with no arguments, and clang
// rejected it ("use of class template requires template arguments"). Its
// body is visible wherever Box is complete (CODEGEN.md §7), so it is
// instantiated implicitly and gets no tier-3 line; Box<i32> itself still
// does.
pub class <T> Box {
    pub var v: T
    fn Box(self, v: T) { self.v = v; }
    pub fn <U> pick(const self, u: U) -> i32 = (sizeof(U) as i32) + 1
}
fn main() -> i32 {
    var a = Box<i32>(2)
    var b = Box<i32>(1)
    return a.pick(0 as i64) + b.pick(true)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: CODEGEN C++: {{.*}}member_template_of_class_template.k
// CXX: template class{{ ?}}::{{.*}}::Box<signed int>;
// CXX-NOT: ::Box::pick<

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 11
