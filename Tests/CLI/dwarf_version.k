// --dwarf-version only reaches the cc1 line together with -g (no debug info
// means no debug words), and values outside DWARF 2..5 are rejected rather
// than forwarded to clang.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --print-clang-args -g --dwarf-version=4 | %FileCheck %s --check-prefix=V4
// V4: -dwarf-version=4

// RUN: %kairo %s --print-clang-args --dwarf-version=4 | %FileCheck %s --check-prefix=NOG
// NOG-NOT: -dwarf-version

// RUN: { %kairo %s --print-clang-args --dwarf-version=9 2>&1 || true; } | %FileCheck %s --check-prefix=RANGE
// RANGE: out of range [2, 5]
