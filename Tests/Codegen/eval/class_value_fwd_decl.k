pub struct Holder {
    pub var w: *Widget<Pt(2, 3)>
    pub var n: i32
}

pub struct Pt {
    pub var x: i32
    pub var y: i32
    eval fn Pt(self, x: i32, y: i32) {
        self.x = x
        self.y = y
    }
}

class <eval P: Pt> Widget {
    fn area(const self) -> i32 { return P.x * P.y }
}

fn main() -> i32 {
    var g = Widget<Pt(2, 3)>()
    var h = Holder { w: &g, n: 1 }
    return h.w->area() + h.n     // 6 + 1 == 7
}

// EVAL.md 7e: a template over a class-typed value parameter can be
// declared only where the class is complete, so tier 0 does not
// forward-declare it. Holder, written above both, names `*Widget<...>`
// through a pointer: it needed a declaration of Widget ahead of it, and
// got none ("no template named 'Widget'"), and its argument `Pt(2, 3)`
// needed Pt complete ("invalid use of incomplete type"). Widget's forward
// declaration now follows Pt's definition, and Holder's definition follows
// both.

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR-LABEL: CODEGEN C++: {{.*}}class_value_fwd_decl.k
// IR:      struct Pt {
// IR:      template< ::{{([A-Za-z_]+::)*}}class_value_fwd_decl::Pt P> class Widget;
// IR:      struct Holder {
// IR-NEXT:     ::{{([A-Za-z_]+::)*}}class_value_fwd_decl::Widget< ::{{([A-Za-z_]+::)*}}class_value_fwd_decl::Pt(2, 3)> * w

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 7
