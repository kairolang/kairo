// The pretty renderer prints the "[CODE] message" line under the header when
// every label carries its own text, so the caret row's label text is never
// the only description of the diagnostic.
fn divide(a: i32, b: i32) -> i32 requires b != 0 { return a / b }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo --error-format=pretty --no-color --type-check-only %s 2>&1 || true; } | %FileCheck %s --strict-whitespace
// CHECK-LABEL: error @ {{.*}}pretty_message_with_labeled_spans.k:4:43
// CHECK-NEXT:  {{^}}  [SC186E] requires expression is not compile-time evaluable{{$}}
// CHECK:       {{^}}      |                                           depends on runtime value 'b'{{$}}
