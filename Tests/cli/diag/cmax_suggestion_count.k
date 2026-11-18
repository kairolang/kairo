// --cmax-suggestion-count=N keeps at most N fix-its per diagnostic. The
// warning on `x: const i32` carries two (insert const on the binding, remove
// it from the type). Counted with grep so the test does not hardcode columns.
fn params(x: const i32) { }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | { grep -c 'fix-it:' || true; } | %FileCheck %s --check-prefix=DEFAULT
// RUN: { %kairo %s --type-check-only --cmax-suggestion-count=1 2>&1 || true; } | { grep -c 'fix-it:' || true; } | %FileCheck %s --check-prefix=ONE
// RUN: { %kairo %s --type-check-only --cmax-suggestion-count=0 2>&1 || true; } | { grep -c 'fix-it:' || true; } | %FileCheck %s --check-prefix=NONE
// DEFAULT: {{^}}2{{$}}
// ONE: {{^}}1{{$}}
// NONE: {{^}}0{{$}}
