var a = "12" "3"_km
var b = "x"_km "y"

// --- lit wiring -----------------------------------------------------------
// A literal suffix belongs to the whole joined string (P878), on
// whichever segment it is written, so the tree dump shows it once for the
// chain. It printed only the head segment's, so `a` showed no suffix.
// RUN: %kairo %s --syntax-only --print-ast=tree | %FileCheck %s
// CHECK: StringLiteralExpr "12" suffix _km
// CHECK: StringLiteralExpr "x" suffix _km
