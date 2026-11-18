// A container of a record holding a member enum keeps its members typed:
// an unknown enumerator is R025E and a string argument to `reserve` is
// SC063E, with no cascade from an unfilled instance.

ffi "c++" import "vector";

struct Label {
    enum Style derives u8 { Primary, Secondary }
    var n: i32
    var style: Style
}

class Diag {
    var labels: cxx::std::vector<Label>
    fn Diag(self) { self.labels.reserve(4) }
    fn bad(self) -> i32 {
        if self.labels[0].style == Label::Style::Tertiary { return 1 }
        self.labels.reserve("x")
        return 0
    }
}

fn main() -> i32 { return 0 }

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not='error [' --implicit-check-not='I003E'
// CHECK: nested_enum_standin_reject.k:17:50: error [R025E]: no member named 'Tertiary' in 'Style'
// CHECK: nested_enum_standin_reject.k:18:9: error [SC063E]: no matching overload for call to 'reserve'
