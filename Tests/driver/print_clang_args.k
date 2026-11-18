// --print-clang-args prints the cc1 invocation every compile copies, as one
// shell line, and compiles nothing. It is built by the same code the backend
// parses, so the target, the level and the user's header roots in it are
// the ones a compile uses. A word the shell would split is quoted.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --print-clang-args | %FileCheck %s --check-prefix=HOST
// HOST:      clang -cc1 -triple {{[^ ]+}}
// HOST-SAME: -emit-obj
// HOST-SAME: -O0
// HOST-SAME: -x c++ '<injected>'

// RUN: %kairo %s --print-clang-args -O2 --target=aarch64-linux-gnu --ffi-include "/tmp/a b" | %FileCheck %s --check-prefix=CROSS
// CROSS:      clang -cc1 -triple aarch64-linux-gnu
// CROSS-SAME: -I '/tmp/a b'
// CROSS-SAME: -O2

// A failed parse leaves the invocation at its defaults: no line, exit 1.
// RUN: { %kairo --print-clang-args 2>&1; echo "exit $?"; } | %FileCheck %s --check-prefix=BAD
// BAD-NOT: clang -cc1
// BAD:     exit 1
