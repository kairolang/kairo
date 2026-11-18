// A static musl program reads its default thread stack size from the
// PT_GNU_STACK segment's size (musl's own default is 128 KiB). Linking with
// `-z stack-size=8 MiB`, which the toolchain's own musl links pass, gives a
// worker thread an 8 MiB stack: a thread recursing about 800 KiB deep runs to
// completion.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-x86_64-linux-musl, host-x86_64, host-linux
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %S/Inputs/thread_deep_recursion.c --target x86_64-linux-musl --ld-flags=-zstack-size=8388608 -o %t.d/deep --cache-dir %t.d/c
// RUN: %t.d/deep
