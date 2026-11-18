// A new value of a union holds the one field with a default; a second
// field with a default is an error at that field, with a note at the
// first and a fix-it removing the second default. `static` and `eval`
// fields are not part of the value and may have initializers.

union Word {
    var i: i32 = 0
    var f: f32 = 1.0
    var u: u32
    static count: i32 = 0
}

union One {
    var i: i32
    var f: f32 = 2.0
}

fn main() -> i32 {
    var o = One()
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: union_two_defaults.k:8:5: error [SC359E]: only one field of a union may have a default: 'f' and 'i' of 'Word' both have one
// CHECK-NEXT: fix-it:{{.*}}:{8:15-8:21}:""
// CHECK-NEXT: union_two_defaults.k:7:5: note {{.*}}: the first field with a default is here
// CHECK-NOT: error
