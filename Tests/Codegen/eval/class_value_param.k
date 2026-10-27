// EVAL.md 7e: an eval class is a generic value argument when its type is
// structural -- every field `pub`, none a pointer to mutable memory, every
// constructor `eval` -- and is a C++20 class-type template parameter. The
// argument is an eval binding (`Widget<SMALL>`, a string field included:
// its bytes are `__kairo_estr`) or an eval constructor call
// (`Grid<Pt(2, 3)>`); inside the generic, `C.size` is the field of that
// value. The class is defined before the template that takes it.

pub struct Config {
    pub var size: i32
    pub var label: string
    eval fn Config(self, size: i32, label: string) {
        self.size = size
        self.label = label
    }
}

pub struct Pt {
    pub var x: i32
    pub var y: i32
    eval fn Pt(self, x: i32, y: i32) {
        self.x = x
        self.y = y
    }
}

eval SMALL = Config(4, "small")

class <eval C: Config> Widget {
    fn size(const self) -> i32 { return C.size }
    fn label_len(const self) -> usize { return C.label.len }
}

class <eval P: Pt> Grid {
    fn area(const self) -> i32 { return P.x * P.y }
}

fn main() -> i32 {
    var w = Widget<SMALL>()
    var g = Grid<Pt(2, 3)>()
    return w.size() + (w.label_len() as i32) + g.area()     // 4 + 5 + 6 == 15
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR-LABEL: CODEGEN C++: {{.*}}class_value_param.k
// IR:      struct Config {
// IR:      template< ::class_value_param::Config C> class Widget {
// IR:      return C.size;
// IR:      ::class_value_param::Widget< ::class_value_param::SMALL> w =
// IR:      ::class_value_param::Grid< ::class_value_param::Pt(2, 3)> g =

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 15
