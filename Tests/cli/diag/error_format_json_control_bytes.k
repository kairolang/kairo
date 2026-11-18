// --error-format=json escapes the control bytes a message can quote from the
// source: a deprecation reason holding a raw U+0001 and a form feed prints
// them as \u0001 and \f, so each line stays one valid JSON object.
fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: printf '@deprecated("old\001one\014two")\nfn old() -> i32 { return 1 }\nfn main() -> i32 { return old() }\n' > %t.k
// RUN: { %kairo %t.k --type-check-only --error-format=json 2>&1 || true; } | %FileCheck %s
// CHECK: "severity":"warning","code":"SC146W","message":"'old' is deprecated: old\u0001one\ftwo"}
// CHECK: "severity":"note","code":"I900N","message":"'old' was marked deprecated here"}
