// --cxx-include adds a user header root to the clang invocation exactly as
// --ffi-include does, in both the space and the = spelling. Pinned so the two
// spellings of the option cannot drift apart.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --print-clang-args --cxx-include /tmp/cx | %FileCheck %s --check-prefix=SPACE
// SPACE:      clang -cc1
// SPACE-SAME: -I /tmp/cx

// RUN: %kairo %s --print-clang-args --cxx-include=/tmp/cy | %FileCheck %s --check-prefix=EQ
// EQ:      clang -cc1
// EQ-SAME: -I /tmp/cy
