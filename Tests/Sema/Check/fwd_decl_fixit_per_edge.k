// The pointer fix-it of "holds a forward-declared record by value" belongs
// to one edge: the field whose type is exactly that record. A record reached
// THROUGH a field has edges of its own (here a base), and their errors carry
// no fix-it at the outer field. The walk enters `Mid` through `Outer::m`,
// so the base edge of `Mid` is reported while that field is being walked.

class Never

struct Outer {
    pub var m: Mid
    pub var n: Never
}

class Mid derives Never { }

fn main() -> i32 { return 0 }

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning [" --implicit-check-not="fix-it:"
// CHECK: {{.*}}:11:9: error [SC227E]: 'Outer' holds 'Never' by value, but 'Never' is only forward-declared, so its size is unknown
// CHECK-NEXT: fix-it:"{{.*}}":{11:16-11:16}:"unsafe *"
// CHECK-NEXT: {{.*}}:7:1: note [SC227N]: 'Never' is forward-declared here and never defined
// CHECK: {{.*}}:14:19: error [SC227E]: 'Mid' holds 'Never' by value, but 'Never' is only forward-declared, so its size is unknown
// CHECK-NEXT: {{.*}}:7:1: note [SC227N]: 'Never' is forward-declared here and never defined
