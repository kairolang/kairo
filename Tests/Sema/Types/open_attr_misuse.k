// `@open` applies to a plain enum only: on an ADT enum (always closed, no
// cast makes its tag), a struct or a function it is SC001E, labelled on the
// attribute, noting the declaration, with a fix-it removing it.

@open struct S { var x: i32 = 0 }
@open enum Adt { Some { v: i32 }, None }
@open fn func() {}
@open enum Fine derives u8 { A, B }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG:      open_attr_misuse.k:5:1: error [SC001E]: '@open' does not apply to this declaration; only a plain enum can be open
// DIAG-NEXT: fix-it:"{{.*}}open_attr_misuse.k":{5:1-5:6}:""
// DIAG-NEXT: open_attr_misuse.k:5:7: note [I900N]: the attribute is on this declaration
// DIAG:      open_attr_misuse.k:6:1: error [SC001E]: '@open' does not apply to an ADT enum: no cast makes its tag, so it is always closed
// DIAG-NEXT: fix-it:"{{.*}}open_attr_misuse.k":{6:1-6:6}:""
// DIAG-NEXT: open_attr_misuse.k:6:7: note [I900N]: the attribute is on this declaration
// DIAG:      open_attr_misuse.k:7:1: error [SC001E]: '@open' does not apply to this declaration; only a plain enum can be open
// DIAG-NEXT: fix-it:"{{.*}}open_attr_misuse.k":{7:1-7:6}:""
// DIAG-NEXT: open_attr_misuse.k:7:7: note [I900N]: the attribute is on this declaration
