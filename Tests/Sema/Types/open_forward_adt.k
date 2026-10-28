// `@open` on a forward declaration of what its definition makes an ADT:
// the parser saw no payloads there, so TypeResolve reports it (SC001E),
// noting the definition, with a fix-it removing the attribute.

@open enum Shape derives u8

enum Shape derives u8 { Dot { x: i32 }, Empty }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG:      open_forward_adt.k:5:1: error [SC001E]: '@open' does not apply to an ADT enum: no cast makes its tag, so it is always closed
// DIAG-NEXT: fix-it:"{{.*}}open_forward_adt.k":{5:1-5:6}:""
// DIAG-NEXT: open_forward_adt.k:7:6: note [I900N]: its definition has payload variants
