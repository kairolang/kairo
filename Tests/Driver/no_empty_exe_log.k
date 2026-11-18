// A compiler run that logged nothing leaves no `<exe>.log` beside the
// binary, and removes an empty one an earlier run left, so an installed tree
// is not littered (or written to) by every compile.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: shell
// RUN: rm -rf %t.d && mkdir -p %t.d && cp %kairo_bin %t.d/kairo
// RUN: %t.d/kairo --type-check-only --no-stdlib %s
// RUN: test ! -e %t.d/kairo.log
// RUN: : > %t.d/kairo.log
// RUN: %t.d/kairo --type-check-only --no-stdlib %s
// RUN: test ! -e %t.d/kairo.log
// RUN: rm -rf %t.d
