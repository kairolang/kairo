// The 32-bit path (Lib/builtin/base/hash.k): i686 has no 128-bit integer,
// so fold_mul / mum take the four-product mul_wide, and usize is 32 bits
// (to_usize folds the 64-bit hash). keys.k, map_api.k and lifetime.k are
// run there unchanged.
fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang, sysroot-i686-linux-musl
// RUN: rm -rf %t.d
// RUN: %kairo %S/keys.k --target=i686-linux-musl -o %t.keys --cache-dir %t.d/k
// RUN: %t.keys; test $? -eq 100
// RUN: %kairo %S/map_api.k --target=i686-linux-musl -o %t.api --cache-dir %t.d/a
// RUN: %t.api; test $? -eq 100
// RUN: %kairo %S/lifetime.k --target=i686-linux-musl -o %t.life --cache-dir %t.d/l
// RUN: %t.life; test $? -eq 100
