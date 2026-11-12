// The line numbers below are load-bearing; the notes are under the code.
ffi "c++" import "pretty_label_other_file.h"
fn take(a: string) {}
fn grow(b: u64) {
    p961_cmt(b)   // a trailing comment; pretty_label_other_file.h:5 declares p961_cmt
    p961_nocmt(b)
    p961_other(b)
	p961_tab(b)
    take("éé"); p961_utf8(b)
    p961_multi(
        b)
}

// The pretty renderer drew every label whose LINE NUMBER matched the error's
// line on the error's caret row, whatever file the label was in. SC063E puts
// each candidate's declaration range on the diagnostic, so a candidate
// declared on line 5 of the header drew its whole width from column 1 under a
// call on line 5 of this file (the R070E repro had buf.h:7 under
// buf.k:7). Each call here is SC063E: u64 does not convert to size_t.
//
//   line 5  same line number as its declaration, with a trailing comment
//   line 6  same line number, no comment (the comment was never the trigger)
//   line 7  declaration on header line 3: the control, right before the fix
//   line 8  tab-indented: the caret row mirrors the tab (it had one space)
//   line 9  two-byte UTF-8 before the call: carets count cells, not bytes
//   line 10 a range that ends on line 11: it runs to the end of line 10
//           (its end column, 11's, was measured against line 10)
//
// The header's lines 7-11 declare nothing, so lines 7-10 test only their
// own shape. Only the error's caret rows are checked: the notes under them
// render each label in its own file.

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo --error-format=pretty --no-color --type-check-only %s 2>&1 || true; } | %FileCheck %s --strict-whitespace
// CHECK-LABEL: error @ {{.*}}pretty_label_other_file.k:5:5
// CHECK:      {{^}}    5 |     p961_cmt(b)   // a trailing comment; pretty_label_other_file.h:5 declares p961_cmt{{$}}
// CHECK-NEXT: {{^}}      |     ^^^^^^^^^^^{{$}}
// CHECK-NEXT: {{^}}      |     [SC063E] no matching overload for call to 'p961_cmt'{{$}}
// CHECK-LABEL: error @ {{.*}}pretty_label_other_file.k:6:5
// CHECK:      {{^}}    6 |     p961_nocmt(b){{$}}
// CHECK-NEXT: {{^}}      |     ^^^^^^^^^^^^^{{$}}
// CHECK-NEXT: {{^}}      |     [SC063E] no matching overload for call to 'p961_nocmt'{{$}}
// CHECK-LABEL: error @ {{.*}}pretty_label_other_file.k:7:5
// CHECK:      {{^}}    7 |     p961_other(b){{$}}
// CHECK-NEXT: {{^}}      |     ^^^^^^^^^^^^^{{$}}
// CHECK-NEXT: {{^}}      |     [SC063E] no matching overload for call to 'p961_other'{{$}}
// CHECK-LABEL: error @ {{.*}}pretty_label_other_file.k:8:2
// CHECK:      {{^}}    8 | 	p961_tab(b){{$}}
// CHECK-NEXT: {{^}}      | 	^^^^^^^^^^^{{$}}
// CHECK-NEXT: {{^}}      | 	[SC063E] no matching overload for call to 'p961_tab'{{$}}
// CHECK-LABEL: error @ {{.*}}pretty_label_other_file.k:9:19
// CHECK:      {{^}}    9 |     take("éé"); p961_utf8(b){{$}}
// CHECK-NEXT: {{^}}      |                 ^^^^^^^^^^^^{{$}}
// CHECK-NEXT: {{^}}      |                 [SC063E] no matching overload for call to 'p961_utf8'{{$}}
// CHECK-LABEL: error @ {{.*}}pretty_label_other_file.k:10:5
// CHECK:      {{^}}   10 |     p961_multi({{$}}
// CHECK-NEXT: {{^}}      |     ^^^^^^^^^^^{{$}}
// CHECK-NEXT: {{^}}      |     [SC063E] no matching overload for call to 'p961_multi'{{$}}
