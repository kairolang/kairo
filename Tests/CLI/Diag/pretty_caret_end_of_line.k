// The pretty renderer gave a point at the end of its line (here: where the
// declaration after `virtual` should start) an empty caret row: the caret was
// clamped to the line's length and lost its one cell. It now sits in the
// cell just past the text. Line numbers and columns are load-bearing.
virtual

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo --error-format=pretty --no-color --type-check-only %s 2>&1 || true; } | %FileCheck %s --strict-whitespace
// CHECK-LABEL: error @ {{.*}}pretty_caret_end_of_line.k:5:8
// CHECK:      {{^}}    5 | virtual{{$}}
// CHECK-NEXT: {{^}}      |        ^{{$}}
// CHECK-NEXT: {{^}}      |        [S063E] expected a declaration after modifiers{{$}}
