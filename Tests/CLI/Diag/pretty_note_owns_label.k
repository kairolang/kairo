// A note's label belongs to the note. Line numbers are load-bearing.
ffi "c++" import "pretty_label_other_file.h"
fn divide(a: i32, b: i32) -> i32 requires b != 0 { return a / b }
fn grow(n: u64) { p961_other(n) }

// `b.note(loc, msg)->first(range)` reads as "label the note", but note()
// returns the parent's builder, so 249 call sites put the note's range on
// the PARENT diagnostic; the note itself had no label and drew one caret at
// its location. The label showed on the parent's caret row when it shared
// the parent's line (line 3: SC186E's own label is `b`, its note's is the
// whole `b != 0`), and could land on another file's line. The sites
// now say child_first, which labels the last note.
//
//   line 3  the parent underlines `b` only; the note underlines `b != 0`
//   line 4  the SC063E note underlines the whole header declaration, which
//           a language server also gets as the related range

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo --error-format=pretty --no-color --type-check-only %s 2>&1 || true; } | %FileCheck %s --strict-whitespace
// CHECK-LABEL: error @ {{.*}}pretty_note_owns_label.k:3:43
// CHECK:      {{^}}    3 | fn divide(a: i32, b: i32) -> i32 requires b != 0 { return a / b }{{$}}
// CHECK-NEXT: {{^}}      |                                           ^{{$}}
// CHECK-NEXT: {{^}}      |                                           depends on runtime value 'b'{{$}}
// CHECK-NEXT: {{^}}    note @ {{.*}}pretty_note_owns_label.k:3:43{{$}}
// CHECK:      {{^}}       3 | fn divide(a: i32, b: i32) -> i32 requires b != 0 { return a / b }{{$}}
// CHECK-NEXT: {{^}}         |                                           ^^^^^^ for runtime-conditional dispatch, use 'where'{{$}}
// CHECK-LABEL: error @ {{.*}}pretty_note_owns_label.k:4:19
// CHECK:      {{^}}    note @ {{.*}}pretty_label_other_file.h:3:1{{$}}
// CHECK:      {{^}}       3 | void p961_other(size_t n);{{$}}
// CHECK-NEXT: {{^}}         | ^^^^^^^^^^^^^^^^^^^^^^^^^ candidate not viable: cannot convert argument of type 'u64' to parameter 'n' of type 'usize'{{$}}
