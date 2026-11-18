// A linked Mach-O executable carries an LC_UUID load command, also with
// --build-id=none: without it the loader refuses to launch the binary on
// recent macOS releases. The link line never passes -no_uuid.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-arm64-macosx, llvm-objdump
// RUN: %kairo %s --target=arm64-apple-macosx14.0 --print-ld-args | %FileCheck %s --check-prefix=ARGS
// RUN: %kairo %s --target=arm64-apple-macosx14.0 --build-id=none --print-ld-args | %FileCheck %s --check-prefix=ARGS
// ARGS-NOT: -no_uuid
// RUN: rm -f %t.exe %t.none.exe
// RUN: %kairo %s --target=arm64-apple-macosx14.0 -o %t.exe
// RUN: %kairo %s --target=arm64-apple-macosx14.0 --build-id=none -o %t.none.exe
// RUN: %objdump --macho --private-headers %t.exe | %FileCheck %s --check-prefix=UUID
// RUN: %objdump --macho --private-headers %t.none.exe | %FileCheck %s --check-prefix=UUID
// UUID: cmd LC_UUID
