// A written `const fn` may call only const callees. `abs` is clang-marked
// const, so it is accepted; `strlen` is only pure (it reads memory), and
// `rand` is unmarked: both are SC200E here. A `@pure` fn may call a
// clang-marked pure callee (`strlen`), and still not `rand`.

import std::c_char

ffi "c" import "string.h"
ffi "c" import "stdlib.h"

fn ok_abs(x: i32) const -> i32 { return abs(x) }
fn bad_len(s: unsafe *const c_char) const -> usize { return strlen(s) }
fn bad_rand() const -> i32 { return rand() }
@pure fn ok_len(s: unsafe *const c_char) -> usize { return strlen(s) }
@pure fn bad_rand_pure() -> i32 { return rand() }

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --error-format=basic 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [SC200E]"
// CHECK-DAG: infer_foreign_const_rejects.k:12:{{[0-9]+}}: error [SC200E]: 'bad_len'{{.*}}strlen
// CHECK-DAG: infer_foreign_const_rejects.k:13:{{[0-9]+}}: error [SC200E]: 'bad_rand'{{.*}}rand
// CHECK-DAG: infer_foreign_const_rejects.k:15:{{[0-9]+}}: error [SC200E]: 'bad_rand_pure'{{.*}}rand
