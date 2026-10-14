// --diag-show-context=false hides the source snippet in the pretty renderer;
// the message still prints, under the "severity @ file:line" header. The
// default shows the source line and the caret row.
fn main() -> i32 {
    var shown_marker: i32 = u1;
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --error-format=pretty 2>&1 || true; } | %FileCheck %s --check-prefix=ON
// RUN: { %kairo %s --type-check-only --error-format=pretty --diag-show-context=false 2>&1 || true; } | %FileCheck %s --check-prefix=OFF --implicit-check-not=shown_marker
// ON: error @ {{.*}}diag_show_context.k:
// ON: shown_marker
// OFF: error @ {{.*}}diag_show_context.k:
// OFF-NEXT: [R020E] use of undeclared identifier 'u1'
