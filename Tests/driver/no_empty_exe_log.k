// A compiler run that logged nothing leaves no `<exe>.log` beside the
// binary, and removes an empty one an earlier run left, so an installed tree
// is not littered (or written to) by every compile.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: shell
// The staged tree is mirrored with links so the copied binary finds its
// libraries and clang; only the compiler itself is a real copy, so the log
// would be written beside it and not into the tree under test.
// RUN: rm -rf %t.d && mkdir -p %t.d/bin
// RUN: for e in $(dirname %kairo_bin)/../*; do [ "$(basename $e)" = bin ] || ln -s "$(realpath $e)" %t.d/; done
// RUN: for e in $(dirname %kairo_bin)/*; do ln -s "$(realpath -s $e)" %t.d/bin/; done
// RUN: rm %t.d/bin/kairo && cp %kairo_bin %t.d/bin/kairo
// RUN: %t.d/bin/kairo --type-check-only --no-stdlib %s
// RUN: test ! -e %t.d/bin/kairo.log
// RUN: : > %t.d/bin/kairo.log
// RUN: %t.d/bin/kairo --type-check-only --no-stdlib %s
// RUN: test ! -e %t.d/bin/kairo.log
// RUN: rm -rf %t.d
