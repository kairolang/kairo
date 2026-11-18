// Hashing a u64 through `Hash` on AArch64 at -O2: two folds, each one `mul`
// and one `umulh`, with no call and no branch.

@no_inline fn hash_u64(v: u64, seed: u64) -> u64 {
    var h = Hasher(seed)
    v.hash(&h)
    return h.finish()
}

fn main() -> i32 = (hash_u64(1, 2) == 0) as i32

// --- lit wiring ---
// REQUIRES: newlib
// REQUIRES: sysroot-aarch64-linux-gnu
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo_new %s -O2 --target=aarch64-linux-gnu -S -o %t.s --cache-dir %t.d
// RUN: %FileCheck %s --input-file=%t.s
// CHECK-LABEL: {{^}}_ZN{{.*}}8hash_u64Emm:
// CHECK-NOT:     {{^[[:space:]]+(bl|blr|b|b\.[a-z]+|cbn?z|tbn?z)[[:space:]]}}
// CHECK:         umulh
// CHECK-NOT:     {{^[[:space:]]+(bl|blr|b|b\.[a-z]+|cbn?z|tbn?z)[[:space:]]}}
// CHECK:         umulh
// CHECK-NOT:     {{^[[:space:]]+(bl|blr|b|b\.[a-z]+|cbn?z|tbn?z)[[:space:]]}}
// CHECK:         ret
