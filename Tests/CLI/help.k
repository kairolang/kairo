// -h and --help print the usage text and exit 0 without compiling. The USAGE
// line embeds argv[0], so only its prefix is pinned; the flag list must name
// both spellings so a rename of either shows up here.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo --help | %FileCheck %s
// RUN: %kairo -h | %FileCheck %s
// CHECK: USAGE:
// CHECK: -h, --help
// CHECK: -V, --version
