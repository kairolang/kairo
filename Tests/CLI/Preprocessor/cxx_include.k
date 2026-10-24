// --cxx-include adds a user header root to the clang invocation exactly as
// --ffi-include does, in both the space and the = spelling. Pinned so the two
// spellings of the option cannot drift apart. -I reaches clang too (it is
// also a .k search dir), ahead of the clang-only two.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --print-clang-args --cxx-include /tmp/cx | %FileCheck %s --check-prefix=SPACE
// SPACE:      clang -cc1
// SPACE-SAME: -I /tmp/cx

// RUN: %kairo %s --print-clang-args --cxx-include=/tmp/cy | %FileCheck %s --check-prefix=EQ
// EQ:      clang -cc1
// EQ-SAME: -I /tmp/cy

// RUN: %kairo %s --print-clang-args -I /tmp/ci --cxx-include /tmp/cz | %FileCheck %s --check-prefix=DASHI
// DASHI:      clang -cc1
// DASHI-SAME: -I /tmp/ci -I /tmp/cz
