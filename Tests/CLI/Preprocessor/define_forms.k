// --define (-D) accepts NAME (value 1, as gcc/clang) and NAME=VALUE, and
// rejects an empty NAME instead of silently dropping the define. The long
// spelling is used so this pins the preprocessor's handling independently of
// how the short -D is split by the argument parser. A define is a
// parameterless macro, invoked as NAME!.

fn main() -> i32 { return FOO! + BAR! }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --dump-preprocessed --define=FOO --define=BAR=7 | %FileCheck %s --check-prefix=OK
// OK: return 1 + 7
// RUN: { %kairo %s --type-check-only --define==5 2>&1 || true; } | %FileCheck %s --check-prefix=BAD
// BAD: error [U001E]: invalid -D argument '=5': expected NAME or NAME=VALUE with a non-empty NAME
