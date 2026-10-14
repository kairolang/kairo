// --builtins-dir names the directory of builtin modules; the runtime root the
// backend adds as a header root is its PARENT. Pinned so a change to how the
// root is derived (and so which headers a compile sees) is noticed. Nothing
// validates that the directory exists, so a made-up path is enough to observe it.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --print-clang-args --builtins-dir=/my/root/builtin | %FileCheck %s
// CHECK: -I /my/root
