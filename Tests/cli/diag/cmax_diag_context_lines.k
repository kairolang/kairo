// --cmax-diag-context-lines=N shows N source lines up to and including the
// caret line in the pretty renderer. The default 3 is two lead-in lines.
fn main() -> i32 {
    var first_marker: i32 = 1;
    var second_marker: i32 = 2;
    var third_marker: i32 = u1;
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --error-format=pretty 2>&1 || true; } | %FileCheck %s --check-prefix=THREE
// RUN: { %kairo %s --type-check-only --error-format=pretty --cmax-diag-context-lines=2 2>&1 || true; } | %FileCheck %s --check-prefix=TWO --implicit-check-not=first_marker
// RUN: { %kairo %s --type-check-only --error-format=pretty --cmax-diag-context-lines=1 2>&1 || true; } | %FileCheck %s --check-prefix=ONE --implicit-check-not=first_marker --implicit-check-not=second_marker
// THREE: first_marker
// THREE: second_marker
// THREE: third_marker
// TWO: second_marker
// TWO: third_marker
// ONE: third_marker
