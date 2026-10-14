// --cmax-token-count is per file and its error used to carry no file name, so
// a limit blown by a builtin/std file looked like the user's own file's fault.
// The message now names the file that tripped it.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --cmax-token-count=5 2>&1 || true; } | %FileCheck %s
// CHECK: error [S065E]: preprocessor token budget exceeded in '{{.*}}token_count_names_file.k' (limit 5); raise it with --cmax-token-count=N
