// --install-name sets a dylib's install name (-install_name). Only a dylib has
// one, so on an executable the flag is reported and dropped. Without the flag a
// dylib gets @rpath/<output name>.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-arm64-macosx
// RUN: %kairo %s --target=arm64-apple-macosx14.0 --print-ld-args --shared --install-name=@rpath/libfoo.dylib | %FileCheck %s --check-prefix=SET
// SET: -dylib
// SET: -install_name @rpath/libfoo.dylib
// RUN: { %kairo %s --target=arm64-apple-macosx14.0 --print-ld-args --install-name=@rpath/libfoo.dylib 2>&1 || true; } | %FileCheck %s --check-prefix=EXE
// EXE: warning [L001W]: --install-name only applies to a dylib
