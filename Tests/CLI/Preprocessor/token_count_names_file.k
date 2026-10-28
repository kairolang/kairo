// --cmax-token-count is per file and its error used to carry no file name, so
// a limit blown by a builtin/std file looked like the user's own file's fault.
// The message now names the file that tripped it.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// Every builtin file blows a limit of 5 as well, one S065E each, ahead of
// this file's: --cmax-errors=0 so the default cap of 20 does not hide it.
// RUN: { %kairo %s --type-check-only --cmax-token-count=5 --cmax-errors=0 2>&1 || true; } | %FileCheck %s
// CHECK: error [S065E]: preprocessor token budget exceeded in '{{.*}}token_count_names_file.k' (limit 5); raise it with --cmax-token-count=N
