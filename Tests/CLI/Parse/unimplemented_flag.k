// A flag marked unimplemented (Command::mark_unimplemented) still parses, but
// using it warns U005W without failing the build, and --help tags it. The
// registry marks --print-pass-pipeline as the first user of the mechanism.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --print-pass-pipeline 2>&1 || true; } | %FileCheck %s
// CHECK: warning [U005W]: flag '--print-pass-pipeline' is accepted but not yet implemented; it has no effect
// RUN: %kairo --help | %FileCheck %s --check-prefix=HELP
// HELP: --print-pass-pipeline
// HELP-SAME: [not implemented]
