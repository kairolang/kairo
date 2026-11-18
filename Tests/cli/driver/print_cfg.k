// --print-cfg prints the --cfg values the driver collected, one per line and
// in the order given, then stops: nothing is compiled. A bare name and a
// name=value pair are both kept verbatim, so a build script can see exactly
// what the preprocessor's cfg set will contain.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --print-cfg --cfg=foo --cfg=bar=baz | %FileCheck %s
// CHECK:      foo
// CHECK-NEXT: bar=baz
