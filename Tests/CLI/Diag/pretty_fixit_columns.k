// The line numbers below are load-bearing, notes under the code.
enum Opcode derives u8 { Nop, Halt }
fn casts(b: u32) -> i32 {
    var p = b as Opcode
    return 0
    p = Opcode::Nop
    p = p
}

// The pretty renderer draws a fix-it IN the primary line (removed text kept,
// inserted text added) with '-'/'+' markers on the caret row. Three ways it
// put them, or the carets around them, somewhere other than the edit:
//
//   line 4  SC127E's fix replaces `b` with `(b as u8)`. The label covers
//           `b as Opcode`, across the insert, and stopped nine cells short
//           of its end: only labels starting after an edit were moved right.
//   line 6  SC003W's fix removes lines 6-7. Its end column (7's) was
//           measured against line 6, striking 5 of the line's 15 columns;
//           it now runs to the end of line 6, as a label's range does.
//   use.k   (Inputs/pretty_fixit) R047E's fix inserts `pub` in lib.k at
//           line 5, the line number of the use. A fix-it is placed by line
//           number like a label, so the insert was spliced into
//           use.k's line 5 at column 1. It belongs to the other file.

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo --error-format=pretty --no-color --type-check-only %s 2>&1 || true; } | %FileCheck %s --strict-whitespace
// RUN: cd %S/Inputs/pretty_fixit && { %kairo --error-format=pretty --no-color --type-check-only use.k 2>&1 || true; } | %FileCheck %s --strict-whitespace --check-prefix=OTHER
// CHECK-LABEL: error @ {{.*}}pretty_fixit_columns.k:4:13
// CHECK:      {{^}}    4 |     var p = b(b as u8) as Opcode{{$}}
// CHECK-NEXT: {{^}}      |             -+++++++++^^^^^^^^^^{{$}}
// CHECK-NEXT: {{^}}      |             [SC127E] casting 'u32' to 'Opcode' needs its underlying type 'u8'; cast to 'u8' first{{$}}
// CHECK-LABEL: warning @ {{.*}}pretty_fixit_columns.k:6:5
// CHECK:      {{^}}      6 |     p = Opcode::Nop{{$}}
// CHECK-NEXT: {{^}}        |     ---------------{{$}}
// CHECK-NEXT: {{^}}        |     [SC003W] unreachable code; the statement above always transfers control out of this block{{$}}
// OTHER-LABEL: error @ {{.*}}use.k:5:12
// OTHER:      {{^}}    5 |     return hidden_fn(){{$}}
// OTHER-NEXT: {{^}}      |            ^^^^^^^^^{{$}}
// OTHER-NEXT: {{^}}      |            [R047E] 'hidden_fn' is imported but is private to its file{{.*}}
